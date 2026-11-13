#!/usr/bin/env python3
# File: Tools/ci/linux_runtime.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Fingerprint native Swift ELF inputs and their actual Ubuntu runtime closure.

The caller supervises this helper as one 30-second metadata command. Its own
finite scan, hashing and subprocess limits leave time for the caller's cleanup.
Only the already provisioned native compiler tree and installed system tools are
passed to ldd; downloaded project artifacts are never executed or inspected here.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time


SECONDS = 24
MAX_ENTRIES = 200_000
MAX_ELFS = 512
MAX_LIBRARIES = 512
MAX_HASH_BYTES = 8 * 1024 ** 3
MAX_OUTPUT_BYTES = 2 * 1024 ** 2
MAX_FACT_BYTES = 120 * 1024
CRT_PACKAGES = ('libc6-dev', 'libgcc-13-dev', 'libstdc++-13-dev', 'linux-libc-dev')
SHA256 = re.compile(r'[0-9a-f]{64}')
PACKAGE = re.compile(r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9-]+)?')


class Budget:
    """Share one finite scan/hash/command allowance without resetting per child."""

    def __init__(self):
        self.deadline = time.monotonic() + SECONDS
        self.hashed = 0

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('Linux ABI observation deadline exhausted')
        return remaining

    def digest(self, path):
        """Bound real file reads and reject mutation during the observation."""
        self.remaining()
        before = path.stat()
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
            raise ValueError('Linux ABI input is not a nonempty regular file')
        if self.hashed + before.st_size > MAX_HASH_BYTES:
            raise ValueError('Linux ABI hashing exceeded its finite byte limit')
        digest = hashlib.sha256()
        observed = 0
        with path.open('rb') as stream:
            while block := stream.read(1024 ** 2):
                self.remaining()
                observed += len(block)
                if self.hashed + observed > MAX_HASH_BYTES or observed > before.st_size:
                    raise ValueError('Linux ABI input grew during hashing')
                digest.update(block)
        after = path.stat()
        if (observed != before.st_size or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)):
            raise ValueError('Linux ABI input changed during hashing')
        self.hashed += observed
        return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def command(arguments, budget, *, allowed_codes=(0,), environment=None):
    """Bound both output pipes and the remaining aggregate time, including reaping."""
    output = {'stdout': bytearray(), 'stderr': bytearray()}
    environment = {**os.environ, **(environment or {}), 'LC_ALL': 'C', 'LANG': 'C'}
    # ldd must observe the same library search overrides as the actual compiler.
    process = subprocess.Popen(list(map(str, arguments)), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment, process_group=0)
    try:
        with selectors.DefaultSelector() as selector:
            for name, stream in (('stdout', process.stdout), ('stderr', process.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map() or process.poll() is None:
                remaining = budget.remaining()
                for key, _ in selector.select(min(0.05, remaining)):
                    data = os.read(key.fd, 8192)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    output[key.data].extend(data)
                    if sum(map(len, output.values())) > MAX_OUTPUT_BYTES:
                        raise ValueError('Linux ABI command output exceeded its finite byte limit')
            if process.returncode not in allowed_codes:
                error = output['stderr'].decode('utf-8', errors='replace').strip()[:1024]
                raise ValueError(f'Linux ABI command failed ({Path(arguments[0]).name}): {error}')
    finally:
        # A new group within the caller's session lets us reclaim ldd's shell and
        # loader descendants. It remains visible to the enclosing Linux session
        # supervisor; start_new_session would incorrectly escape that ownership.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=1)
        process.stdout.close()
        process.stderr.close()
    return output['stdout'].decode('utf-8', errors='strict')


def native_elf(path, *, interpreter=False):
    """Return None for non-native/relocatable files, otherwise dynamic or static.

    SDK archives contain other architectures and relocatable objects. They are
    outside this native runtime closure; malformed native executable headers fail.
    """
    with path.open('rb') as stream:
        header = stream.read(64)
        if not header.startswith(b'\x7fELF'):
            return None
        if len(header) < 20:
            raise ValueError('truncated ELF identity in the active Swift tree')
        if header[4:6] != b'\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 62:
            return None
        if struct.unpack_from('<H', header, 16)[0] not in (2, 3):
            return None
        if len(header) != 64:
            raise ValueError('truncated native ELF header')
        offset = struct.unpack_from('<Q', header, 32)[0]
        size, count = struct.unpack_from('<HH', header, 54)
        if not 56 <= size <= 256 or not 0 < count <= 1024 or offset + size * count > path.stat().st_size:
            raise ValueError('invalid native ELF program headers')
        stream.seek(offset)
        table = stream.read(size * count)
        if len(table) != size * count:
            raise ValueError('truncated native ELF program headers')
        kinds = {struct.unpack_from('<I', table, index * size)[0] for index in range(count)}
        if interpreter:
            return 3 in kinds
        return 'dynamic' if 2 in kinds else 'static'


def toolchain_files(root, budget):
    """Inspect a finite tree, deduplicating aliases without following directory links."""
    files, dynamic, entries = {}, [], 0
    for directory, folders, names in os.walk(root / 'usr', followlinks=False):
        budget.remaining()
        entries += len(folders) + len(names)
        if entries > MAX_ENTRIES:
            raise ValueError('active Swift tree exceeded its finite entry limit')
        folders.sort()
        for name in sorted(names):
            budget.remaining()
            path = Path(directory, name).resolve(strict=True)
            if not path.is_relative_to(root):
                raise ValueError('active Swift tree contains a file outside its installation')
            if path in files or not path.is_file():
                continue
            kind = native_elf(path)
            if kind is None:
                continue
            if len(files) >= MAX_ELFS:
                raise ValueError('active Swift tree exceeded its finite native ELF limit')
            files[path] = budget.digest(path)
            if kind == 'dynamic':
                dynamic.append(path)
    if not files or not dynamic:
        raise ValueError('active Swift tree has no native ELF compiler/runtime inputs')
    return files, sorted(dynamic)


def dependencies(text, seeds):
    """Retain the full resolved dependency graph, omitting only ASLR addresses/vDSO."""
    if len(text.encode()) > MAX_OUTPUT_BYTES:
        raise ValueError('native ELF dependency output exceeded its finite byte limit')
    seeds = set(map(str, seeds))
    graph, current = {}, None
    for line in text.splitlines():
        value = line.strip()
        if not value:
            continue
        if value.endswith(':') and value[:-1] in seeds:
            current = value[:-1]
            if current in graph:
                raise ValueError('duplicate native ELF dependency section')
            graph[current] = {}
            continue
        if current is None:
            raise ValueError('native ELF dependency output has no input identity')
        if re.fullmatch(r'linux-vdso\.so\.1 \(0x[0-9a-fA-F]+\)', value):
            continue
        match = re.fullmatch(r'(?:(\S+)\s+=>\s+)?(/\S+)\s+\(0x[0-9a-fA-F]+\)', value)
        if match is None:
            raise ValueError(f'unresolved or malformed native ELF dependency: {value[:160]}')
        name, path = match.groups()
        path = str(Path(path).resolve(strict=True))
        name = name or Path(path).name
        if name in graph[current] and graph[current][name] != path:
            raise ValueError('ambiguous native ELF dependency resolution')
        graph[current][name] = path
    if set(graph) != seeds or any(not rows for rows in graph.values()):
        raise ValueError('native ELF dependency output omitted an input or its runtime closure')
    paths = {Path(path) for rows in graph.values() for path in rows.values()}
    if len(paths) > MAX_LIBRARIES:
        raise ValueError('native ELF runtime closure exceeded its finite library limit')
    return graph, paths


def package_aliases(path):
    """Account for Ubuntu usrmerge while asking dpkg about the actual resolved file."""
    value = str(path)
    aliases = {value}
    if value.startswith(('/usr/lib/', '/usr/lib64/', '/usr/bin/', '/usr/sbin/')):
        aliases.add(value[4:])
    return aliases


def package_facts(paths, budget, *, run=command):
    """Bind every system file to installed package versions plus common manifest CRTs."""
    paths = set(paths)
    queries = sorted({name for path in paths for name in package_aliases(path)})
    if any(any(char in name for char in '\0\r\n*?[]') for name in queries):
        raise ValueError('unsupported runtime package query path')
    owners = {path: set() for path in paths}
    if queries:
        # One usrmerge alias may be absent from dpkg's file list; validate complete
        # ownership below instead of treating that expected exit1 as success.
        text = run(['dpkg-query', '--search', '--', *queries], budget, allowed_codes=(0, 1))
        for line in text.splitlines():
            try:
                packages, filename = line.split(': ', 1)
                path = Path(filename).resolve(strict=True)
            except (ValueError, OSError) as error:
                raise ValueError('malformed runtime package ownership') from error
            if path not in owners:
                raise ValueError('unexpected runtime package ownership path')
            for package in packages.split(', '):
                if not PACKAGE.fullmatch(package):
                    raise ValueError('invalid runtime package owner')
                owners[path].add(package)
        missing = sorted(str(path) for path, packages in owners.items() if not packages)
        if missing:
            detail = ', '.join(missing[:5])
            if len(missing) > 5:
                detail += f' (+{len(missing) - 5} more)'
            raise ValueError('native runtime library or tool has no installed package owner: ' + detail)
    selected = sorted(set(CRT_PACKAGES) | {name for packages in owners.values() for name in packages})
    text = run(['dpkg-query', '--show', '--showformat=${binary:Package}\t${Version}\t${db:Status-Status}\n',
                '--', *selected], budget)
    versions = {}
    for line in text.splitlines():
        fields = line.split('\t')
        if (len(fields) != 3 or not PACKAGE.fullmatch(fields[0]) or fields[2] != 'installed'
                or not re.fullmatch(r'[A-Za-z0-9.+:~\-]+', fields[1]) or fields[0] in versions):
            raise ValueError('missing or malformed installed runtime package version')
        versions[fields[0]] = fields[1]
    def resolve(package):
        candidates = [name for name in versions if name == package or (':' not in package and name.split(':')[0] == package)]
        if len(candidates) != 1:
            raise ValueError('required runtime/CRT package version is unavailable or ambiguous')
        return candidates[0]
    required = {resolve(package) for package in selected}
    if set(versions) != required:
        raise ValueError('unexpected installed runtime package version')
    return ({str(path): sorted(resolve(name) for name in packages) for path, packages in owners.items()},
            dict(sorted(versions.items())))


def observe(*, swift=None, budget=None, run=command):
    """Observe native bytes and packages; never equate unrelated weekly image tools."""
    budget = budget or Budget()
    if platform.system() != 'Linux' or platform.machine().lower() not in ('x86_64', 'amd64'):
        raise ValueError('Linux ABI observation requires native Linux x64')
    executable = Path(swift or shutil.which('swift') or '').resolve(strict=True)
    if executable.parent.name != 'bin' or executable.parent.parent.name != 'usr':
        raise ValueError('active Swift must use a dedicated usr/bin toolchain layout')
    root = executable.parent.parent.parent
    if root == Path('/'):
        raise ValueError('active Swift must use a dedicated installation root')
    files, dynamic = toolchain_files(root, budget)
    if executable not in files:
        raise ValueError('active Swift is not a native compiler ELF in its installation')
    tools = {}
    for name in ('clang', 'ld', 'ld.gold', 'ld.lld'):
        value = shutil.which(name)
        if value is None:
            if name in ('clang', 'ld'):
                raise ValueError(f'required native compiler/linker is unavailable: {name}')
            continue
        path = Path(value).resolve(strict=True)
        if native_elf(path) != 'dynamic':
            raise ValueError('required native compiler/linker is not a dynamic native ELF')
        tools[name] = {'path': str(path), 'sha256': files.get(path) or budget.digest(path)}
        dynamic.append(path)
    seeds = sorted(set(dynamic))
    if len(seeds) < 2:
        raise ValueError('native Swift runtime closure is incomplete')
    # Shared Swift libraries are dlopened by a Swift process which already owns
    # the native runtime. Give standalone ldd that explicit library context while
    # inspecting executable lookup under the actual, unchanged environment.
    inherited = os.environ.get('LD_LIBRARY_PATH')
    search = inherited.split(':') if inherited is not None else []
    search += [str(root / 'usr/lib/swift/linux'), str(root / 'usr/lib/swift/host'), str(root / 'usr/lib')]
    if any(not absolute_path(path) for path in search):
        raise ValueError('native runtime library search paths must be explicit absolute paths')
    search = list(dict.fromkeys(search))
    executables = {path for path in seeds if native_elf(path, interpreter=True)}
    executables.update(Path(row['path']) for row in tools.values())
    graph, libraries = {}, set()
    for paths, environment in ((sorted(executables), {}),
                               (sorted(set(seeds) - executables), {'LD_LIBRARY_PATH': ':'.join(search)})):
        if not paths:
            continue
        output = run(['ldd', '--', *paths], budget, environment=environment)
        if len(paths) == 1:
            output = str(paths[0]) + ':\n' + output
        observed, resolved = dependencies(output, paths)
        graph.update(observed)
        libraries.update(resolved)
    if len(libraries) > MAX_LIBRARIES:
        raise ValueError('native Swift runtime closure exceeded its finite library limit')
    external = {path for path in libraries | {Path(row['path']) for row in tools.values()}
                if not path.is_relative_to(root)}
    owners, packages = package_facts(external, budget, run=run)
    library_facts = {}
    for path in sorted(libraries):
        library_facts[str(path)] = {'sha256': files.get(path) or budget.digest(path),
                                  'packages': owners.get(str(path), [])}
    for row in tools.values():
        row['packages'] = owners.get(row['path'], [])
    manifest = {str(path.relative_to(root)): digest for path, digest in files.items()}
    facts = {'schemaVersion': 1, 'architecture': 'x86_64', 'elfClass': 64,
             'toolchainRoot': str(root), 'toolchainELFCount': len(files),
             'librarySearchPaths': {'inherited': inherited, 'sharedLibraries': search},
             'toolchainELFSHA256': hashlib.sha256(canonical(manifest)).hexdigest(),
             'dependencyGraphSHA256': hashlib.sha256(canonical(graph)).hexdigest(),
             'libraries': library_facts, 'packages': packages, 'nativeTools': tools}
    budget.remaining()
    validate_facts(facts)
    return facts


def absolute_path(value):
    """Require canonical absolute textual paths, without interpreting host files."""
    return (isinstance(value, str) and value.startswith('/') and value != '/'
            and not any(character in value for character in '\0\r\n')
            and str(Path(value)) == value and '..' not in Path(value).parts)


def validate_facts(facts):
    """Reject partial/legacy/malformed helper output before admitting compatibility."""
    keys = {'schemaVersion', 'architecture', 'elfClass', 'toolchainRoot', 'toolchainELFCount',
            'toolchainELFSHA256', 'dependencyGraphSHA256', 'libraries', 'packages', 'nativeTools', 'librarySearchPaths'}
    if (not isinstance(facts, dict) or set(facts) != keys or type(facts['schemaVersion']) is not int
            or facts['schemaVersion'] != 1 or facts['architecture'] != 'x86_64'
            or type(facts['elfClass']) is not int or facts['elfClass'] != 64
            or not absolute_path(facts['toolchainRoot'])
            or type(facts['toolchainELFCount']) is not int or not 0 < facts['toolchainELFCount'] <= MAX_ELFS
            or any(not isinstance(facts[name], str) or not SHA256.fullmatch(facts[name])
                   for name in ('toolchainELFSHA256', 'dependencyGraphSHA256'))):
        raise ValueError('required native Linux ABI facts are unavailable or malformed')
    libraries, packages, tools = (facts[name] for name in ('libraries', 'packages', 'nativeTools'))
    if (not isinstance(libraries, dict) or not 0 < len(libraries) <= MAX_LIBRARIES
            or not isinstance(packages, dict) or not packages or not isinstance(tools, dict)
            or not {'clang', 'ld'} <= set(tools) <= {'clang', 'ld', 'ld.gold', 'ld.lld'}):
        raise ValueError('native Linux ABI library/package/tool closure is incomplete')
    for name, version in packages.items():
        if (not isinstance(name, str) or not PACKAGE.fullmatch(name) or not isinstance(version, str)
                or not re.fullmatch(r'[A-Za-z0-9.+:~\-]+', version)):
            raise ValueError('invalid native Linux ABI package version')
    if not set(CRT_PACKAGES) <= {name.split(':')[0] for name in packages}:
        raise ValueError('native Linux ABI common CRT packages are incomplete')
    search = facts['librarySearchPaths']
    if (not isinstance(search, dict) or set(search) != {'inherited', 'sharedLibraries'}
            or (search['inherited'] is not None and not isinstance(search['inherited'], str))
            or not isinstance(search['sharedLibraries'], list) or not search['sharedLibraries']
            or any(not absolute_path(value) for value in search['sharedLibraries'])
            or len(search['sharedLibraries']) != len(set(search['sharedLibraries']))):
        raise ValueError('invalid native Linux ABI library search paths')
    rows = [(name, row, {'sha256', 'packages'}) for name, row in libraries.items()]
    for row in tools.values():
        if not isinstance(row, dict):
            raise ValueError('invalid native Linux ABI compiler/linker facts')
        rows.append((row.get('path'), row, {'path', 'sha256', 'packages'}))
    for name, row, required in rows:
        if (not absolute_path(name) or not isinstance(row, dict) or set(row) != required
                or not isinstance(row['sha256'], str) or not SHA256.fullmatch(row['sha256'])
                or not isinstance(row['packages'], list) or any(not isinstance(name, str) for name in row['packages'])
                or row['packages'] != sorted(set(row['packages']))
                or any(package not in packages for package in row['packages'])
                or (not Path(name).is_relative_to(facts['toolchainRoot']) and not row['packages'])):
            raise ValueError('invalid native Linux ABI file identity or package ownership')
    if len(canonical(facts)) > MAX_FACT_BYTES:
        raise ValueError('native Linux ABI facts exceed their finite schema/output limit')
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        value = observe()
        print(canonical(value).decode())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Linux ABI observation failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
