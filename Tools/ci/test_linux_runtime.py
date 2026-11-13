#!/usr/bin/env python3
# File: Tools/ci/test_linux_runtime.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Native ELF/runtime identity is complete, deterministic and finitely observed."""

import copy
import hashlib
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import linux_runtime as runtime


def elf(path, *, machine=62, kind=3, dynamic=True, suffix=b''):
    """Write only enough genuine ELF structure to exercise native header selection."""
    path.parent.mkdir(parents=True, exist_ok=True)
    header = bytearray(64)
    header[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', header, 16, kind, machine)
    struct.pack_into('<Q', header, 32, 64)
    struct.pack_into('<HH', header, 54, 56, 1)
    table = bytearray(56)
    struct.pack_into('<I', table, 0, 2 if dynamic else 1)
    path.write_bytes(header + table + suffix)
    return path


class NativeELFTests(unittest.TestCase):
    def test_native_dynamic_and_static_inputs_exclude_cross_arch_and_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.assertEqual(runtime.native_elf(elf(root / 'dynamic')), 'dynamic')
            self.assertEqual(runtime.native_elf(elf(root / 'static', dynamic=False)), 'static')
            self.assertIsNone(runtime.native_elf(elf(root / 'arm', machine=183)))
            self.assertIsNone(runtime.native_elf(elf(root / 'object', kind=1)))
            (root / 'text').write_text('Swift interface')
            self.assertIsNone(runtime.native_elf(root / 'text'))
            (root / 'bad').write_bytes(b'\x7fELF')
            with self.assertRaisesRegex(ValueError, 'truncated'):
                runtime.native_elf(root / 'bad')

    def test_complete_tree_deduplicates_aliases_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / 'toolchain'
            compiler = elf(root / 'usr/bin/swift')
            (root / 'usr/bin/swiftc').symlink_to('swift')
            elf(root / 'usr/lib/clang/cross-architecture.so', machine=183)
            files, dynamic = runtime.toolchain_files(root, runtime.Budget())
            self.assertEqual(set(files), {compiler})
            self.assertEqual(dynamic, [compiler])
            external = elf(root.parent / 'external')
            (root / 'usr/bin/escape').symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'outside'):
                runtime.toolchain_files(root, runtime.Budget())

    def test_scan_hash_and_deadline_limits_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = elf(root / 'usr/bin/swift')
            with patch.object(runtime, 'MAX_ENTRIES', 0), self.assertRaisesRegex(ValueError, 'entry limit'):
                runtime.toolchain_files(root, runtime.Budget())
            with patch.object(runtime, 'MAX_ELFS', 0), self.assertRaisesRegex(ValueError, 'ELF limit'):
                runtime.toolchain_files(root, runtime.Budget())
            with patch.object(runtime, 'MAX_HASH_BYTES', 1), self.assertRaisesRegex(ValueError, 'byte limit'):
                runtime.Budget().digest(path)
            budget = runtime.Budget()
            budget.deadline = time.monotonic() - 1
            with self.assertRaisesRegex(ValueError, 'deadline'):
                budget.digest(path)


class RuntimeClosureTests(unittest.TestCase):
    def fixture(self, root):
        swift = elf(root / 'toolchain/usr/bin/swift-driver')
        clang = elf(root / 'toolchain/usr/bin/clang')
        linker = elf(root / 'system/bin/ld')
        library = elf(root / 'system/lib/libc.so.6')
        loader = elf(root / 'system/lib/ld-linux-x86-64.so.2')
        names = {'swift': swift, 'clang': clang, 'ld': linker, 'ld.gold': None, 'ld.lld': None}
        owners = {str(linker): 'binutils:amd64', str(library): 'libc6:amd64', str(loader): 'libc6:amd64'}
        commands = []
        self.environments = []

        def run(arguments, budget, **options):
            commands.append(arguments)
            if arguments[0] == 'ldd':
                self.environments.append(options.get('environment'))
                return ''.join((f'{path}:\n' if len(arguments[2:]) > 1 else '') +
                               f' linux-vdso.so.1 (0x1234)\n libc.so.6 => {library} (0x2345)\n'
                               f' {loader} (0x3456)\n' for path in arguments[2:])
            if arguments[1] == '--search':
                return ''.join(f'{package}: {path}\n' for path, package in owners.items())
            selected = sorted(set(owners.values()) | {name + ':amd64' for name in runtime.CRT_PACKAGES})
            return ''.join(f'{name}\t{getattr(self, "package_version", "1.0-1")}\tinstalled\n' for name in selected)
        return swift, names, owners, commands, run

    def observe(self, root, *, mutate=None, environment=None):
        swift, names, _, commands, run = self.fixture(root)
        if mutate:
            mutate(root)
        with patch.object(runtime.platform, 'system', return_value='Linux'), \
                patch.object(runtime.platform, 'machine', return_value='x86_64'), \
                patch.object(runtime.shutil, 'which', side_effect=lambda name: names[name]), \
                patch.dict(os.environ, environment or {}, clear=True):
            return runtime.observe(swift=swift, run=run), commands

    def test_real_file_bytes_and_packages_form_complete_deterministic_closure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            facts, commands = self.observe(root)
            self.assertEqual(facts['toolchainELFCount'], 2)
            self.assertEqual(len(facts['libraries']), 2)
            self.assertEqual(set(facts['nativeTools']), {'clang', 'ld'})
            self.assertEqual(sum(command[0] == 'ldd' for command in commands), 2)
            self.assertEqual(sum(command[0] == 'dpkg-query' for command in commands), 2)
            self.assertEqual(facts, self.observe(root)[0])
            expected = hashlib.sha256((root / 'system/lib/libc.so.6').read_bytes()).hexdigest()
            self.assertEqual(facts['libraries'][str(root / 'system/lib/libc.so.6')]['sha256'], expected)

    def test_compiler_runtime_file_bytes_and_package_revision_drift_change_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            initial = self.observe(root)[0]
            compiler = self.observe(root, mutate=lambda root: elf(
                root / 'toolchain/usr/bin/swift-driver', suffix=b'new compiler'))[0]
            self.assertNotEqual(initial['toolchainELFSHA256'], compiler['toolchainELFSHA256'])
            libraries = self.observe(root, mutate=lambda root: elf(
                root / 'system/lib/libc.so.6', suffix=b'new libc'))[0]
            self.assertNotEqual(initial['libraries'], libraries['libraries'])
            self.package_version = '1.0-2'
            packages = self.observe(root)[0]
            self.assertNotEqual(initial['packages'], packages['packages'])

    def test_explicit_shared_lookup_context_does_not_override_executable_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            facts, _ = self.observe(root, environment={'LD_LIBRARY_PATH': '/custom/lib'})
            self.assertEqual(facts['librarySearchPaths']['inherited'], '/custom/lib')
            self.assertEqual(facts['librarySearchPaths']['sharedLibraries'][0], '/custom/lib')
            self.assertEqual(self.environments[0], {})
            self.assertEqual(self.environments[1], {'LD_LIBRARY_PATH': ':'.join(
                facts['librarySearchPaths']['sharedLibraries'])})
            for value in ('', '.', '/valid::/other', '/valid:relative'):
                with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'search paths'):
                    self.observe(root, environment={'LD_LIBRARY_PATH': value})

    def test_missing_dependencies_and_sections_never_yield_partial_facts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            library = elf(root / 'libc.so.6')
            seed = str(root / 'swift')
            valid = f'{seed}:\n libc.so.6 => {library} (0x1234)\n'
            for invalid in (valid.replace(str(library), 'not found'), '', valid + valid,
                            valid.replace(seed + ':', 'other:'), valid + 'unrecognized output\n'):
                with self.subTest(output=invalid), self.assertRaises(ValueError):
                    runtime.dependencies(invalid, [seed])
            first = runtime.dependencies(valid, [seed])
            second = runtime.dependencies(valid.replace('0x1234', '0xabcdef'), [seed])
            self.assertEqual(first, second)

    def test_package_owner_or_common_crt_gap_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = elf(Path(directory) / 'library')
            with self.assertRaisesRegex(ValueError, 'package owner') as failure:
                runtime.package_facts({path}, runtime.Budget(), run=lambda *args, **kw: '')
            self.assertIn(str(path), str(failure.exception))
            paths = {elf(Path(directory) / f'library-{index}') for index in range(7)}
            with self.assertRaises(ValueError) as failure:
                runtime.package_facts(paths, runtime.Budget(), run=lambda *args, **kw: '')
            self.assertTrue(str(failure.exception).endswith(
                ', '.join(sorted(map(str, paths))[:5]) + ' (+2 more)'))
            with self.assertRaisesRegex(ValueError, 'unavailable'):
                runtime.package_facts(set(), runtime.Budget(), run=lambda *args, **kw: '')
        self.assertEqual(runtime.package_aliases(Path('/usr/lib/x86_64-linux-gnu/libc.so.6')),
                         {'/usr/lib/x86_64-linux-gnu/libc.so.6', '/lib/x86_64-linux-gnu/libc.so.6'})

    def test_partial_or_malformed_abi_schema_never_admits_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            facts, _ = self.observe(Path(directory))
        mutations = [lambda value: value.pop('packages'),
                     lambda value: value.update(schemaVersion=0),
                     lambda value: value.update(schemaVersion=True),
                     lambda value: value.update(elfClass=True),
                     lambda value: value.update(toolchainELFCount=True),
                     lambda value: value.update(toolchainRoot='/'),
                     lambda value: value['packages'].pop('libc6-dev:amd64'),
                     lambda value: value['packages'].pop('linux-libc-dev:amd64'),
                     lambda value: value['packages'].update({'bad': None}),
                     lambda value: value['nativeTools'].update(ld=[]),
                     lambda value: value['nativeTools']['clang'].update(packages=[[]]),
                     lambda value: value['nativeTools']['clang'].pop('path'),
                     lambda value: value.update(librarySearchPaths={'inherited': False, 'sharedLibraries': []}),
                     lambda value: next(iter(value['libraries'].values())).update(packages=[])]
        for mutation in mutations:
            invalid = copy.deepcopy(facts)
            mutation(invalid)
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                runtime.validate_facts(invalid)


class CommandBoundsTests(unittest.TestCase):
    def test_nonzero_exit_output_overflow_and_deadline_are_terminal(self):
        with self.assertRaisesRegex(ValueError, 'command failed'):
            runtime.command([sys.executable, '-c', 'raise SystemExit(2)'], runtime.Budget())
        with patch.object(runtime, 'MAX_OUTPUT_BYTES', 32), self.assertRaisesRegex(ValueError, 'output exceeded'):
            runtime.command([sys.executable, '-c', 'print("x"*64)'], runtime.Budget())
        budget = runtime.Budget()
        budget.deadline = time.monotonic() + 0.05
        with self.assertRaisesRegex(ValueError, 'deadline'):
            runtime.command([sys.executable, '-c', 'import time;time.sleep(5)'], budget)

    def test_timeout_reclaims_descendant_even_when_parent_has_exited(self):
        """A child holding stdout cannot survive the command's finite deadline."""
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'child.pid'
            script = ('import subprocess,sys;from pathlib import Path;'
                      'child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);'
                      'Path(sys.argv[1]).write_text(str(child.pid))')
            budget = runtime.Budget()
            budget.deadline = time.monotonic() + 0.3
            with self.assertRaisesRegex(ValueError, 'deadline'):
                runtime.command([sys.executable, '-c', script, str(pidfile)], budget)
            child = int(pidfile.read_text())
            for _ in range(20):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                # Linux container PID1 may leave an already-killed orphan zombie;
                # it cannot execute or hold inherited pipes after group cleanup.
                status = Path(f'/proc/{child}/stat')
                self.assertTrue(status.is_file() and status.read_text().split()[2] == 'Z')


if __name__ == '__main__':
    unittest.main()
