# File: Tools/ci/test_native_provisioning.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reject untrusted provisioning without downloads, native builds or installation."""

from contextlib import redirect_stderr
from copy import deepcopy
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import native_provisioning as provisioning
import scheduling_policy


FINGERPRINT = "52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"
HISTORICAL_FINGERPRINT = "E813C892820A6FA13755B268F167DF1ACF9CE069"
GPG_STATUS = f"[GNUPG:] VALIDSIG {FINGERPRINT} 2026-10-12 1791829232 0 4 0 1 10 00 {FINGERPRINT}"
APPLE_STATUS = """Package \"swift.pkg\":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Swift Open Source (V9AUD2URP3)
       Expires: 2027-02-01 22:12:15 +0000
"""


class ProvisioningTests(unittest.TestCase):
    """Exercise actual hashes and boundaries using tiny authenticated-payload fixtures."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.policy = provisioning.load_policy()
        self.payload = b"fixture for an upstream authenticated compiler distribution\n"
        self.policy["platforms"]["linux-x64"]["distributionSHA256"] = hashlib.sha256(self.payload).hexdigest()
        self.policy["platforms"]["macos-arm64"]["distributionSHA256"] = hashlib.sha256(self.payload).hexdigest()
        self.plan = self.make_plan()

    def make_plan(self, target="linux-x64", root=None):
        """Model a fresh exact-image plan; no executable comes from a restored cache."""
        root = root or self.root
        image = {"imageOS": "ubuntu24", "imageVersion": "20261108.1", "architecture": "x86_64"}
        return {"schemaVersion": 1, "platform": target, "root": str(root),
                "receiptPath": str(root / "evidence/provisioning.json"),
                "startedEpoch": time.time(), "startedAt": "2026-11-12T00:00:00+00:00",
                "allowanceSeconds": 600,
                "policySHA256": hashlib.sha256(provisioning.canonical(self.policy)).hexdigest(),
                "cachePath": str(root / "distribution"), "cacheEnabled": target != "windows-x64",
                "cacheSaveAllowed": False, "image": image,
                "cacheKey": provisioning.compatibility_key(self.policy, target, image)}

    def fixture(self, plan=None):
        """Write only the strict payload/signature/identity cache file set."""
        plan = plan or self.plan
        cache = Path(plan["cachePath"])
        cache.mkdir(parents=True)
        payload = provisioning.payload_path(plan, self.policy)
        payload.write_bytes(self.payload)
        distribution = self.policy["platforms"][plan["platform"]]
        if distribution["signature"] == "gpg-detached":
            payload.with_name(payload.name + ".sig").write_bytes(b"fixture detached signature")
        provisioning.write_json(cache / "identity.json", {"schemaVersion": 1, "key": plan["cacheKey"],
                                "distributionURL": distribution["distributionURL"],
                                "distributionSHA256": distribution["distributionSHA256"]})
        return payload

    def verify(self, *, status=GPG_STATUS, plan=None):
        """Mock only OS signature executables, retaining actual file/metadata hashing."""
        with patch.object(provisioning, "signing_keys", return_value=self.root / "signing-keys"), \
                patch.object(provisioning, "run_command", return_value=status):
            return provisioning.verify_distribution(plan or self.plan, self.policy)

    def test_checked_in_policy_pins_and_budget_match_shared_scheduling(self):
        """A provisioning optimization cannot quietly acquire a larger setup reserve."""
        policy = provisioning.load_policy()
        self.assertEqual(policy["allowanceSeconds"], scheduling_policy.load_policy()["reservesSeconds"]["setup"])
        self.assertEqual(policy["platforms"]["linux-x64"]["distributionSHA256"],
                         "7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b")
        self.assertEqual(policy["platforms"]["macos-arm64"]["distributionSHA256"],
                         "c34e7e5fb0be4bcd61decfd40db1766434d8952d68e37aed90bcff4e8547951c")

    def test_policy_rejects_disabled_signatures_missing_pins_and_unbounded_limits(self):
        for field, value in (("signature", None), ("distributionSHA256", "unknown")):
            policy = deepcopy(self.policy)
            policy["platforms"]["linux-x64"][field] = value
            path = self.root / "policy.json"
            provisioning.write_json(path, policy)
            with self.subTest(field=field), self.assertRaises(ValueError):
                provisioning.load_policy(path)
        policy = deepcopy(self.policy)
        policy["allowanceSeconds"] = 601
        provisioning.write_json(path, policy)
        with self.assertRaises(ValueError):
            provisioning.load_policy(path)

    def test_cache_trust_allows_default_branch_only_and_never_any_pr_event(self):
        for event, ref, branch, expected in (
                ("push", "refs/heads/main", "main", True),
                ("workflow_dispatch", "refs/heads/main", "main", True),
                ("pull_request", "refs/pull/8/merge", "main", False),
                ("pull_request_target", "refs/heads/main", "main", False),
                ("push", "refs/heads/feature", "main", False),
                ("push", "refs/tags/1.0", "main", False),
                ("push", "refs/heads/main", "", False),
                ("", "refs/heads/main", "main", False)):
            with self.subTest(event=event, ref=ref, branch=branch):
                self.assertEqual(provisioning.cache_save_allowed({"GITHUB_EVENT_NAME": event,
                                 "GITHUB_REF": ref, "DISCORDKIT_DEFAULT_BRANCH": branch}), expected)

    def test_every_compatibility_axis_changes_the_exact_cache_key(self):
        baseline = provisioning.compatibility_key(self.policy, "linux-x64", self.plan["image"])
        variants = []
        for field, value in (("cacheSchemaVersion", 2), ("installerPolicy", "changed"), ("swiftVersion", "6.5")):
            policy = deepcopy(self.policy)
            policy[field] = value
            variants.append((policy, "linux-x64", self.plan["image"]))
        for field, value in (("distributionSHA256", "f" * 64), ("distributionURL", "https://download.swift.org/different")):
            policy = deepcopy(self.policy)
            policy["platforms"]["linux-x64"][field] = value
            variants.append((policy, "linux-x64", self.plan["image"]))
        for field, value in (("imageOS", "different"), ("imageVersion", "20261109.1"),
                             ("architecture", "arm64"), ("sdk", "different")):
            variants.append((self.policy, "linux-x64", dict(self.plan["image"], **{field: value})))
        variants.append((self.policy, "macos-arm64", self.plan["image"]))
        for policy, target, facts in variants:
            self.assertNotEqual(baseline, provisioning.compatibility_key(policy, target, facts))

    def test_prepare_exports_only_exact_cache_path_and_fresh_receipt(self):
        root = self.root / "setup"
        output = self.root / "plan.json"
        github_output = self.root / "github-output"
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                patch.object(provisioning, "image_facts", return_value=self.plan["image"]), \
                patch.dict(os.environ, {"DISCORDKIT_DEFAULT_BRANCH": "main", "GITHUB_EVENT_NAME": "pull_request",
                                        "GITHUB_REF": "refs/pull/8/merge"}, clear=True):
            plan = provisioning.prepare("auto", root, output, github_output=github_output)
        self.assertFalse(plan["cacheSaveAllowed"])
        exports = dict(line.split("=", 1) for line in github_output.read_text().splitlines())
        self.assertEqual(exports["cache-path"], str(root.resolve() / "distribution"))
        self.assertEqual(exports["cache-save"], "false")
        self.assertEqual(exports["cache-enabled"], "true")
        self.assertNotIn("restore-key", exports)
        self.assertEqual(json.loads(Path(plan["receiptPath"]).read_text())["status"], "prepared")

    def test_prepare_rejects_symlink_root_before_resolving(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                self.assertRaisesRegex(ValueError, "symbolic link"):
            provisioning.prepare("auto", link, self.root / "plan.json")

    def test_prepared_plan_rejects_policy_change_expiry_and_wrong_actual_host(self):
        path = self.root / "plan.json"
        provisioning.write_json(path, self.plan)
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"):
            self.assertEqual(provisioning.load_plan(path), self.plan)
            changed = deepcopy(self.plan)
            changed["policySHA256"] = "0" * 64
            provisioning.write_json(path, changed)
            with self.assertRaisesRegex(ValueError, "current policy"):
                provisioning.load_plan(path)
            changed = deepcopy(self.plan)
            changed["startedEpoch"] -= 600
            provisioning.write_json(path, changed)
            with self.assertRaisesRegex(ValueError, "allowance exhausted"):
                provisioning.load_plan(path)
        provisioning.write_json(path, self.plan)
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", side_effect=ValueError("wrong host")), \
                self.assertRaisesRegex(ValueError, "wrong host"):
            provisioning.load_plan(path)

    def test_signature_success_requires_pinned_fingerprint_after_real_hash(self):
        self.fixture()
        verification = self.verify()
        self.assertEqual(verification["signer"], FINGERPRINT)
        self.assertTrue(verification["signatureVerified"])
        self.assertEqual(verification["sha256"], hashlib.sha256(self.payload).hexdigest())
        for status in ("", GPG_STATUS.replace(FINGERPRINT, "F" * 40), "[GNUPG:] GOODSIG somebody"):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "allowed Swift"):
                self.verify(status=status)

    def test_signature_subprocess_failure_is_never_accepted(self):
        self.fixture()
        with patch.object(provisioning, "signing_keys", return_value=self.root), \
                patch.object(provisioning, "run_command", side_effect=subprocess.CalledProcessError(1, ["gpg"])), \
                self.assertRaises(subprocess.CalledProcessError):
            provisioning.verify_distribution(self.plan, self.policy)

    def test_poisoned_bytes_cannot_be_authorized_by_rewriting_cache_manifest(self):
        payload = self.fixture()
        payload.write_bytes(b"attacker-controlled executable")
        identity_path = payload.parent / "identity.json"
        identity = json.loads(identity_path.read_text())
        identity["distributionSHA256"] = hashlib.sha256(payload.read_bytes()).hexdigest()
        provisioning.write_json(identity_path, identity)
        with patch.object(provisioning, "run_command") as run, self.assertRaisesRegex(ValueError, "identity is stale"):
            provisioning.verify_distribution(self.plan, self.policy)
        run.assert_not_called()
        identity["distributionSHA256"] = self.policy["platforms"]["linux-x64"]["distributionSHA256"]
        provisioning.write_json(identity_path, identity)
        with patch.object(provisioning, "run_command") as run, self.assertRaisesRegex(ValueError, "SHA256"):
            provisioning.verify_distribution(self.plan, self.policy)
        run.assert_not_called()

    def test_stale_wrong_platform_and_extra_credential_files_fail_before_signature(self):
        payload = self.fixture()
        identity_path = payload.parent / "identity.json"
        original = json.loads(identity_path.read_text())
        for field, value in (("key", "stale-schema-key"), ("distributionURL", self.policy["platforms"]["macos-arm64"]["distributionURL"])):
            identity = dict(original, **{field: value})
            provisioning.write_json(identity_path, identity)
            with self.subTest(field=field), patch.object(provisioning, "run_command") as run, \
                    self.assertRaisesRegex(ValueError, "identity is stale"):
                provisioning.verify_distribution(self.plan, self.policy)
            run.assert_not_called()
        provisioning.write_json(identity_path, original)
        (payload.parent / "credentials").write_text("must never be accepted")
        with self.assertRaisesRegex(ValueError, "unexpected files"):
            self.verify()

    def test_missing_symlinked_and_oversized_payloads_fail_before_execution(self):
        payload = self.fixture()
        payload.unlink()
        with self.assertRaisesRegex(ValueError, "missing or unexpected"):
            self.verify()
        payload.symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.verify()
        payload.unlink()
        payload.write_bytes(self.payload)
        policy = deepcopy(self.policy)
        policy["maximumDistributionBytes"] = 2
        with self.assertRaisesRegex(ValueError, "oversized"):
            provisioning.verify_distribution(self.plan, policy)

    def test_mac_package_requires_apple_trust_notarization_exact_leaf_and_pkg_suffix(self):
        plan = self.make_plan("macos-arm64")
        payload = self.fixture(plan)
        self.assertEqual(payload.suffix, ".pkg")
        self.assertTrue(self.verify(status=APPLE_STATUS, plan=plan)["signatureVerified"])
        for status in (APPLE_STATUS.replace("V9AUD2URP3", "EVILTEAMID"),
                       APPLE_STATUS.replace("Notarization: trusted by the Apple notary service", "Notarization: unknown"),
                       APPLE_STATUS.replace("Status: signed by a developer certificate issued by Apple for distribution", "Status: no signature"),
                       APPLE_STATUS.replace("1. Developer ID Installer", "2. Developer ID Installer")):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "trusted Swift"):
                self.verify(status=status, plan=plan)

    def test_key_import_is_isolated_uncached_and_both_fingerprints_required(self):
        calls = []

        def run(plan, name, arguments, **keywords):
            calls.append((name, list(map(str, arguments))))
            if name.startswith("verify-signing-fingerprint"):
                return "fpr:::::::::" + str(arguments[-1]) + ":"
            return ""

        with patch.object(provisioning, "run_command", side_effect=run):
            directory = provisioning.signing_keys(self.plan)
        self.assertEqual(directory, self.root / "signing-keys")
        self.assertNotEqual(directory.parent, Path(self.plan["cachePath"]))
        self.assertIn("--compressed", calls[0][1])
        self.assertIn("https://www.swift.org/keys/all-keys.asc", calls[0][1])
        for name, arguments in calls[1:]:
            self.assertEqual(arguments[arguments.index("--homedir") + 1], str(directory))
        self.assertEqual({arguments[-1] for name, arguments in calls if name.startswith("verify-signing")},
                         {FINGERPRINT, HISTORICAL_FINGERPRINT})
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        # A separate fresh job must re-import keys rather than trust prior state.
        fresh = self.make_plan(root=self.root / "missing-key")
        Path(fresh["root"]).mkdir()
        with patch.object(provisioning, "run_command", return_value=""), \
                self.assertRaisesRegex(ValueError, "pinned signing fingerprint"):
            provisioning.signing_keys(fresh)

    def test_prerequisite_supervision_reserves_cleanup_inside_same_600_seconds(self):
        self.plan["startedEpoch"] = time.time() - 580
        captured = {}

        def execute(command, repository, log, *, stdout_log, deadline):
            captured.update(command=command, deadline=deadline)
            stdout_log.write_text("bounded output")

        with patch.object(provisioning, "execute", side_effect=execute):
            result = provisioning.run_command(self.plan, "prerequisite", ["apt-get", "update"])
        self.assertEqual(result, "bounded output")
        self.assertLessEqual(captured["command"].timeout, 12)
        self.assertGreater(captured["command"].timeout, 10)
        self.plan["startedEpoch"] -= 30
        with patch.object(provisioning, "execute") as execute, self.assertRaisesRegex(ValueError, "exhausted"):
            provisioning.run_command(self.plan, "prerequisite", ["apt-get", "update"])
        execute.assert_not_called()

    def test_cold_and_hit_authenticate_before_install_and_produce_same_phase4_identity(self):
        cold = self.plan
        hit = self.make_plan(root=self.root / "hit")
        self.fixture(hit)
        records = []
        events = []
        target_info = {"target": {"triple": "x86_64-unknown-linux-gnu"},
                       "paths": {"runtimeResourcePath": "/opt/discordkit/swift/usr/lib/swift",
                                 "runtimeLibraryPaths": ["/opt/discordkit/swift/usr/lib/swift/linux"]}}

        def run(plan, name, arguments, **keywords):
            events.append(name)
            if name == "verify-distribution-signature":
                return GPG_STATUS
            if name == "compiler-version":
                return "Swift version 6.4.1 (swift-6.4.1-RELEASE)"
            if name == "compiler-target":
                return json.dumps(target_info)
            raise AssertionError(name)

        def install(plan, policy):
            events.append("install")
            self.assertIn("verify-distribution-signature", events)
            return Path("/opt/discordkit/swift-6.4.1-RELEASE-ubuntu24.04/usr/bin")

        for plan, cache_hit in ((cold, False), (hit, True)):
            events.clear()
            output = Path(plan["root"]) / "github-path"
            environment = Path(plan["root"]) / "github-env"
            with patch.object(provisioning, "load_policy", return_value=self.policy), \
                    patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                    patch.object(provisioning, "image_facts", return_value=plan["image"]), \
                    patch.object(provisioning, "download_distribution", side_effect=lambda plan, policy: self.fixture(plan)) as download, \
                    patch.object(provisioning, "signing_keys", return_value=self.root / "signing-keys"), \
                    patch.object(provisioning, "run_command", side_effect=run), \
                    patch.object(provisioning, "install_distribution", side_effect=install):
                record = provisioning.provision(plan, cache_hit=cache_hit, github_path=output, github_env=environment)
            self.assertEqual(download.call_count, 0 if cache_hit else 1)
            self.assertEqual(events, ["verify-distribution-signature", "install", "compiler-version", "compiler-target"])
            self.assertEqual(record["status"], "passed")
            self.assertEqual(record["targetInfo"], target_info)
            self.assertIn(record["binPath"], output.read_text())
            self.assertIn("DISCORDKIT_PROVISIONING_RECEIPT=", environment.read_text())
            records.append(record)
        for field in ("targetInfo", "swiftVersion", "binPath", "verification", "distribution", "policySHA256"):
            self.assertEqual(records[0][field], records[1][field])
        self.assertEqual(records[0]["downloadedBytes"], len(self.payload))
        self.assertEqual(records[1]["downloadedBytes"], 0)
        self.assertEqual(records[1]["cacheBytesReused"], len(self.payload))
        self.assertLess(records[1]["elapsedSeconds"], 600)

    def test_bad_hit_fails_explicitly_retains_failed_receipt_and_never_installs_or_exports(self):
        payload = self.fixture()
        payload.write_bytes(b"poisoned cache")
        output = self.root / "github-path"
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                patch.object(provisioning, "image_facts", return_value=self.plan["image"]), \
                patch.object(provisioning, "download_distribution") as download, \
                patch.object(provisioning, "install_distribution") as install, \
                patch.object(provisioning, "compiler_identity") as identity, \
                self.assertRaisesRegex(ValueError, "SHA256"):
            provisioning.provision(self.plan, cache_hit=True, github_path=output)
        download.assert_not_called()
        install.assert_not_called()
        identity.assert_not_called()
        self.assertFalse(output.exists())
        receipt = json.loads(Path(self.plan["receiptPath"]).read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["cache"]["hit"])

    def test_changed_image_fails_before_distribution_or_compiler_execution(self):
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                patch.object(provisioning, "image_facts", return_value={"imageVersion": "changed"}), \
                patch.object(provisioning, "download_distribution") as download, \
                self.assertRaisesRegex(ValueError, "image or SDK changed"):
            provisioning.provision(self.plan)
        download.assert_not_called()

    def test_windows_cache_disabled_and_provision_explicitly_unqualified(self):
        plan = self.make_plan("windows-x64")
        self.assertFalse(plan["cacheEnabled"])
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="windows-x64"), \
                patch.object(provisioning, "image_facts", return_value=plan["image"]), \
                patch.object(provisioning, "compiler_identity") as identity, \
                self.assertRaisesRegex(ValueError, "not qualified"):
            provisioning.provision(plan)
        identity.assert_not_called()

    def test_prerequisite_failure_and_expired_cli_plan_have_terminal_failed_receipts(self):
        error = subprocess.CalledProcessError(1, ["apt-get", "update"])
        with patch.object(provisioning, "execute", side_effect=error), self.assertRaises(subprocess.CalledProcessError):
            provisioning.run_command(self.plan, "prerequisite", ["apt-get", "update"])
        self.assertEqual(json.loads(Path(self.plan["receiptPath"]).read_text())["status"], "failed")
        path = self.root / "expired-plan.json"
        self.plan["startedEpoch"] -= 600
        provisioning.write_json(path, self.plan)
        with patch.object(provisioning, "load_policy", return_value=self.policy), \
                patch.object(provisioning, "native_platform", return_value="linux-x64"), \
                patch("sys.argv", ["native_provisioning.py", "provision", "--plan", str(path)]), \
                redirect_stderr(io.StringIO()):
            self.assertEqual(provisioning.main(), 1)
        report = json.loads(Path(self.plan["receiptPath"]).read_text())
        self.assertEqual(report["status"], "failed")
        self.assertIn("allowance exhausted", report["error"])

    def test_terminal_failure_rejects_unrelated_report_path(self):
        plan = dict(self.plan, receiptPath=str(self.root / "unrelated.json"))
        provisioning.terminal_failure(plan, ValueError("bad plan"))
        self.assertFalse((self.root / "unrelated.json").exists())

    def test_host_image_and_sdk_identity_require_known_facts_and_include_overrides(self):
        with patch.dict(os.environ, {"ImageOS": "unknown", "ImageVersion": "20261108.1"}, clear=True), \
                self.assertRaisesRegex(ValueError, "ImageOS"):
            provisioning.image_facts("macos-arm64", lambda command: "sdk")
        with patch.dict(os.environ, {"ImageOS": "macos26", "ImageVersion": "20261108.1",
                                    "SDKROOT": "/SDKs/custom.sdk", "DEVELOPER_DIR": "/Xcode/custom"}, clear=True):
            facts = provisioning.image_facts("macos-arm64", lambda command: "SDK observed")
        self.assertEqual(facts["xcode"]["sdkRootOverride"], "/SDKs/custom.sdk")
        self.assertEqual(facts["xcode"]["developerDirectoryOverride"], "/Xcode/custom")

    def test_macos_sdk_identity_normalizes_command_terminators_before_keying(self):
        outputs = {("xcode-select", "-p"): "/Applications/Xcode.app/Contents/Developer",
                   ("xcodebuild", "-version"): "Xcode 26.6\nBuild version 17F113",
                   ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/SDKs/MacOSX26.5.sdk",
                   ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.5",
                   ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "25F70"}
        with patch.dict(os.environ, {"ImageOS": "macos26", "ImageVersion": "20261102.0473.1"}, clear=True):
            clean = provisioning.image_facts("macos-arm64", lambda command: outputs[tuple(command)])
            for ending in ("\n", "\r\n"):
                raw = provisioning.image_facts("macos-arm64", lambda command: outputs[tuple(command)] + ending)
                with self.subTest(ending=ending):
                    self.assertEqual(raw, clean)
                    self.assertEqual(provisioning.compatibility_key(self.policy, "macos-arm64", raw),
                                     provisioning.compatibility_key(self.policy, "macos-arm64", clean))
        self.assertEqual(clean["xcode"]["version"], "Xcode 26.6\nBuild version 17F113")

    def test_macos_sdk_identity_rejects_blank_and_nontext_observations(self):
        with patch.dict(os.environ, {"ImageOS": "macos26", "ImageVersion": "20261102.0473.1"}, clear=True):
            for value in ("", " \n", None, 26.5):
                with self.subTest(value=value), self.assertRaisesRegex(ValueError, "SDK fact"):
                    provisioning.image_facts("macos-arm64", lambda command: value)


if __name__ == "__main__":
    unittest.main()
