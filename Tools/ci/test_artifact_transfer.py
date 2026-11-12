# File: Tools/ci/test_artifact_transfer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Fault-injected artifact transfers; no native compiler, test runner or remote writes."""

from contextlib import contextmanager
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
import base64
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

import artifact_transfer as transfer


def zip_bytes(name="payload.tar.gz", data=b"compiled native bytes"):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(name, data)
    return buffer.getvalue()


class FakeClient:
    def __init__(self, artifacts=None):
        self.run_id = "10"
        self.artifacts = artifacts or []

    @contextmanager
    def within(self, _budget, _deadline):
        yield

    def list_artifacts(self):
        return self.artifacts

    def get_artifact(self, identity):
        return next(item for item in self.artifacts if str(item["id"]) == str(identity))


class ArtifactTransferTests(unittest.TestCase):
    def setUp(self):
        capture = redirect_stdout(io.StringIO())
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def test_first_upload_failure_reuses_bytes_and_unique_candidate_without_build_or_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.zip"
            path.write_bytes(zip_bytes())
            client, seen, attempts = FakeClient(), [], []
            def upload(name, current, digest, _retention, _deadline):
                seen.append((name, current.read_bytes()))
                if len(seen) == 1:
                    raise transfer.TransferError("HTTP 503", transient=True)
                artifact = {"id": "42", "name": name, "digest": "sha256:" + digest,
                            "expired": False, "workflow_run": {"id": 10}}
                client.artifacts.append(artifact)
                return artifact
            with patch.object(transfer, "upload_worker", side_effect=upload) as worker:
                artifact = transfer.upload_prepared(client, "compiled-exact", path, attempts=attempts)
            self.assertEqual([name for name, _ in seen], ["compiled-exact-t1", "compiled-exact-t2"])
            self.assertEqual(seen[0][1], seen[1][1])
            self.assertEqual(artifact["id"], "42")
            self.assertEqual([item["result"] for item in attempts], ["failed", "verified"])
            self.assertEqual(worker.call_count, 2)

    def test_ambiguous_finalization_can_reuse_existing_exact_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.zip"
            path.write_bytes(zip_bytes())
            digest = "sha256:" + transfer.sha256_file(path)
            client = FakeClient([{"id": 7, "name": "compiled-t1", "digest": digest,
                                  "expired": False, "workflow_run": {"id": 10}}])
            with patch.object(transfer, "upload_worker") as worker:
                result = transfer.upload_prepared(client, "compiled", path)
            worker.assert_not_called()
            self.assertEqual(result["id"], "7")

    def test_ambiguous_completed_upload_uses_fresh_candidate_without_deletion(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.zip"
            path.write_bytes(zip_bytes())
            client = FakeClient()
            def upload(name, _path, digest, _retention, _deadline):
                artifact = {"id": len(client.artifacts) + 1, "name": name, "digest": "sha256:" + digest,
                            "expired": False, "workflow_run": {"id": 10}}
                client.artifacts.append(artifact)
                if len(client.artifacts) == 1:
                    raise transfer.TransferError("finalization response lost", transient=True)
                return artifact
            with patch.object(transfer, "upload_worker", side_effect=upload):
                result = transfer.upload_prepared(client, "compiled", path)
            self.assertEqual(len(client.artifacts), 2)
            self.assertEqual(result["name"], "compiled-t2")
            self.assertEqual({item["digest"] for item in client.artifacts}, {result["digest"]})

    def test_existing_candidate_wrong_digest_is_fatal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.zip"
            path.write_bytes(zip_bytes())
            client = FakeClient([{"id": 7, "name": "compiled-t1", "digest": "sha256:" + "0" * 64}])
            attempts = []
            with patch.object(transfer, "upload_worker") as worker, self.assertRaisesRegex(transfer.TransferError, "digest"):
                transfer.upload_prepared(client, "compiled", path, attempts=attempts)
            worker.assert_not_called()
            self.assertEqual(len(attempts), 1)

    def test_authorization_failure_is_never_retried(self):
        operation = Mock(side_effect=transfer.TransferError("HTTP 403"))
        attempts = []
        with self.assertRaises(transfer.TransferError):
            transfer.recover(operation, attempts=attempts)
        self.assertEqual(operation.call_count, 1)
        self.assertEqual(attempts[0]["classification"], "permanent")

    def test_all_transient_attempts_fail_after_three(self):
        operation = Mock(side_effect=transfer.TransferError("HTTP 503", transient=True))
        with self.assertRaises(transfer.TransferError):
            transfer.recover(operation)
        self.assertEqual(operation.call_count, 3)

    def test_aggregate_budget_does_not_start_more_attempts(self):
        budget = transfer.Budget()
        def operation(_attempt, _deadline):
            budget.deadline = time.monotonic() - 1
            raise transfer.TransferError("transient", transient=True)
        attempts = []
        with self.assertRaisesRegex(transfer.TransferError, "deadline"):
            transfer.recover(operation, budget=budget, attempts=attempts)
        self.assertEqual(len(attempts), 1)

    def test_wall_deadline_interrupts_a_stalled_attempt(self):
        started = time.monotonic()
        with self.assertRaisesRegex(transfer.TransferError, "timed out"):
            with transfer.wall_deadline(0.02):
                time.sleep(1)
        self.assertLess(time.monotonic() - started, 0.5)

    def test_nested_expired_deadline_never_rearms_a_delayed_alarm(self):
        previous = object()
        calls = []
        def handler(number, value):
            calls.append(("handler", value))
            return previous
        def timer(kind, seconds, interval=0):
            calls.append(("timer", seconds, interval))
        with patch.object(transfer.signal, "signal", side_effect=handler), \
             patch.object(transfer.signal, "getitimer", return_value=(1.0, 0.0)), \
             patch.object(transfer.signal, "setitimer", side_effect=timer), \
             patch.object(transfer.time, "monotonic", side_effect=[10.0, 12.0]), \
             self.assertRaisesRegex(transfer.TransferError, "timed out"):
            with transfer.wall_deadline(5):
                pass
        self.assertEqual(calls[1:], [("timer", 1.0, 0), ("timer", 0, 0), ("handler", previous)])

    def test_nested_deadline_restores_handler_before_rearming_live_parent(self):
        previous = object()
        calls = []
        def handler(number, value):
            calls.append(("handler", value))
            return previous
        def timer(kind, seconds, interval=0):
            calls.append(("timer", seconds, interval))
        with patch.object(transfer.signal, "signal", side_effect=handler), \
             patch.object(transfer.signal, "getitimer", return_value=(5.0, 0.5)), \
             patch.object(transfer.signal, "setitimer", side_effect=timer), \
             patch.object(transfer.time, "monotonic", side_effect=[10.0, 12.0]):
            with transfer.wall_deadline(10):
                pass
        self.assertEqual(calls[-3:], [("timer", 0, 0), ("handler", previous), ("timer", 3.0, 0.5)])

    def test_expired_parent_cleanup_preserves_primary_failure(self):
        with patch.object(transfer.signal, "signal"), \
             patch.object(transfer.signal, "getitimer", return_value=(1.0, 0.0)), \
             patch.object(transfer.signal, "setitimer") as timer, \
             patch.object(transfer.time, "monotonic", side_effect=[10.0, 12.0]), \
             self.assertRaisesRegex(RuntimeError, "primary failure"):
            with transfer.wall_deadline(5):
                raise RuntimeError("primary failure")
        self.assertEqual([call.args[1] for call in timer.call_args_list], [1.0, 0])

    def test_real_nested_timeouts_leave_no_alarm_or_handler_in_following_work(self):
        # Isolate SIGALRM's default process-termination behavior from unittest.
        script = """import signal, time
import artifact_transfer as transfer
original = signal.getsignal(signal.SIGALRM)
for iteration in range(30):
    try:
        with transfer.wall_deadline(0.002):
            with transfer.wall_deadline(1):
                with transfer.wall_deadline(1):
                    time.sleep(1)
    except transfer.TransferError:
        pass
    assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
    assert signal.getsignal(signal.SIGALRM) == original
    time.sleep(0.001)
print('nested cleanup passed')
"""
        result = subprocess.run([sys.executable, "-c", script], cwd=Path(transfer.__file__).parent,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "nested cleanup passed")

    def test_upload_final_identity_mismatch_is_fatal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "payload.zip"
            path.write_bytes(zip_bytes())
            client = FakeClient([{"id": 7, "name": "wrong", "digest": "sha256:" + "0" * 64}])
            with patch.object(transfer, "upload_worker", return_value={"id": 7}) as worker:
                with self.assertRaisesRegex(transfer.TransferError, "readback"):
                    transfer.upload_prepared(client, "compiled", path)
            self.assertEqual(worker.call_count, 1)

    def test_download_corrupt_bytes_fail_before_extraction_and_without_retry(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        digest = "sha256:" + hashlib.sha256(zip_bytes()).hexdigest()
        artifact = {"id": 7, "digest": digest, "expired": False, "workflow_run": {"id": 10}}
        with patch.object(client, "get_artifact", return_value=artifact), patch.object(client, "_request", return_value=b"corrupt") as read:
            with self.assertRaisesRegex(transfer.TransferError, "digest mismatch"):
                client.download_bytes(7, digest)
        self.assertEqual(read.call_count, 1)

    def test_expiry_and_wrong_run_fail_before_payload_request(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        digest = "sha256:" + "0" * 64
        for changed in ({"expired": True}, {"workflow_run": {"id": 11}}):
            artifact = {"id": 7, "digest": digest, "expired": False, "workflow_run": {"id": 10}, **changed}
            with self.subTest(changed=changed), patch.object(client, "get_artifact", return_value=artifact), patch.object(client, "_request") as read:
                with self.assertRaises(transfer.TransferError):
                    client.download_bytes(7, digest)
                read.assert_not_called()

    def test_compiled_download_streams_to_disk(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        data = zip_bytes()
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        artifact = {"id": 7, "digest": digest, "expired": False, "workflow_run": {"id": 10}}
        with tempfile.TemporaryDirectory() as temporary:
            temporary = str(Path(temporary).resolve())
            destination = Path(temporary) / "payload.zip"
            def read(_path, **kwargs):
                self.assertEqual(kwargs["output"], destination)
                destination.write_bytes(data)
                return destination
            with patch.object(client, "get_artifact", return_value=artifact), patch.object(client, "_request", side_effect=read):
                self.assertEqual(client.download_file(7, digest, destination), destination)
            transfer.extract_zip(destination, Path(temporary) / "extracted")
            self.assertEqual((Path(temporary) / "extracted/payload.tar.gz").read_bytes(), b"compiled native bytes")

    def test_zip_paths_links_duplicates_and_overwrites_fail_closed(self):
        for name in ("../outside", "/absolute", "nested/file", "a\\b", "./file"):
            with tempfile.TemporaryDirectory() as temporary, self.subTest(name=name):
                with self.assertRaises(transfer.TransferError):
                    transfer.extract_zip(zip_bytes(name), Path(temporary) / "destination")
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            info = zipfile.ZipInfo("link")
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, "target")
        with tempfile.TemporaryDirectory() as temporary:
            temporary = str(Path(temporary).resolve())
            with self.assertRaisesRegex(transfer.TransferError, "unsafe"):
                transfer.extract_zip(data.getvalue(), temporary)
            (Path(temporary) / "payload.tar.gz").write_text("existing")
            with self.assertRaisesRegex(transfer.TransferError, "overwrite"):
                transfer.extract_zip(zip_bytes(), temporary)
            self.assertEqual((Path(temporary) / "payload.tar.gz").read_text(), "existing")

    def test_evidence_tar_preserves_colon_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "DocC"
            directory.mkdir()
            (directory / "symbol:method.json").write_text("documentation")
            prepared = Path(temporary) / "payload.zip"
            transfer.prepare_zip([directory], prepared, evidence=True)
            with zipfile.ZipFile(prepared) as outer:
                with tarfile.open(fileobj=io.BytesIO(outer.read("payload.tar.gz")), mode="r:gz") as archive:
                    self.assertEqual(archive.extractfile("DocC/symbol:method.json").read(), b"documentation")

    def test_http_auth_error_is_fatal_and_does_not_leak_credentials(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        error = urllib.error.HTTPError("https://api.github.com", 403, "secret", {}, None)
        with patch("urllib.request.build_opener") as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaisesRegex(transfer.TransferError, "HTTP 403") as failure:
                client.get_run()
            self.assertNotIn("secret", str(failure.exception))
            self.assertEqual(opener.return_value.open.call_count, 1)

    def test_failed_cli_retains_terminal_receipt_and_explicit_regeneration(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            receipt = Path(temporary) / "transfer.json"
            code = transfer.main(["upload", "--name", "evidence", "--path", "missing", "--receipt", str(receipt)])
            report = json.loads(receipt.read_text())
            self.assertEqual(code, 1)
            self.assertEqual(report["status"], "failed")
            self.assertIn("explicitly regenerate only", report["recovery"])

    def test_malformed_producer_input_fails_before_any_upload(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                "GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "secret", "GITHUB_RUN_ID": "10"}):
            archive = Path(temporary) / "root.tar.gz"
            archive.write_bytes(b"compiled")
            metadata = Path(temporary) / "compilation.json"
            metadata.write_text(json.dumps({"archiveSHA256": "0" * 64}))
            with patch.object(transfer, "upload_prepared") as upload:
                code = transfer.main(["upload", "--name", "compiled", "--path", str(archive),
                                      "--producer-metadata", str(metadata), "--producer-receipt-name", "receipt",
                                      "--receipt", str(Path(temporary) / "terminal.json")])
            self.assertEqual(code, 1)
            upload.assert_not_called()

    def test_worker_has_no_hidden_retries_and_dependencies_are_locked(self):
        sdk = Path(transfer.__file__).parent / "artifact-sdk"
        source = (sdk / "upload.mjs").read_text()
        self.assertIn("allowRetries: false", source)
        self.assertIn("maxRetries: 0", source)
        self.assertIn("allowRedirects: false", source)
        self.assertIn("maxTries: 1", source)
        self.assertNotIn("uploadArtifact(", source)
        package = json.loads((sdk / "package.json").read_text())
        lock = json.loads((sdk / "package-lock.json").read_text())
        self.assertEqual(package["dependencies"]["@actions/artifact"], "6.3.1")
        self.assertEqual(lock["packages"]["node_modules/@actions/artifact"]["version"], "6.3.1")

    def test_listing_pagination_retries_changed_snapshot_then_accepts_stable_total(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        for payload in ({"total_count": 2, "artifacts": [{"id": 1}]},
                        {"total_count": True, "artifacts": []},
                        {"total_count": 2, "artifacts": [{"id": 1}, {"id": 1}]}):
            with self.subTest(payload=payload), patch.object(client, "api_json", return_value=payload):
                with self.assertRaises(transfer.TransferError):
                    client.list_artifacts()
        client.attempts.clear()
        with patch.object(client, "api_json", side_effect=[
                {"total_count": 101, "artifacts": [{"id": value} for value in range(1, 101)]},
                {"total_count": 102, "artifacts": [{"id": 101}]},
                {"total_count": 101, "artifacts": [{"id": value} for value in range(1, 101)]},
                {"total_count": 101, "artifacts": [{"id": 101}]}]):
            self.assertEqual(len(client.list_artifacts()), 101)
            self.assertEqual(len(client.attempts), 2)
            self.assertEqual(client.attempts[0]["classification"], "transient")

    def test_response_body_reset_is_classified_and_retried(self):
        client = transfer.GitHubArtifactClient("owner/repo", "secret", "10")
        with patch("urllib.request.build_opener") as opener:
            response = opener.return_value.open.return_value
            response.read.side_effect = [ConnectionResetError(54, "reset"), b'{"id":10}']
            self.assertEqual(client.get_run(), {"id": 10})
            self.assertEqual(opener.return_value.open.call_count, 2)

    @unittest.skipUnless(shutil.which("node"), "Node is required for the JavaScript launcher")
    def test_javascript_launcher_passes_runtime_credentials_and_literal_arguments(self):
        workspace = Path(transfer.__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = directory / "child.json"
            executable = directory / "python3"
            executable.write_text(f"#!{sys.executable}\nimport json,os,sys\n"
                                  "from pathlib import Path\n"
                                  "Path(os.environ['CHILD_RESULT']).write_text(json.dumps({"
                                  "'arguments':sys.argv[1:],'runtime':os.environ['ACTIONS_RUNTIME_TOKEN']}))\n"
                                  "raise SystemExit(17)\n")
            executable.chmod(0o755)
            env = {**os.environ, "GITHUB_WORKSPACE": str(workspace), "CHILD_RESULT": str(result),
                   "ACTIONS_RUNTIME_TOKEN": "test-runtime-token", "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                   "INPUT_ARGUMENTS": json.dumps(["upload", "--name", "literal $(command)"])}
            completed = subprocess.run([shutil.which("node"), str(workspace / ".github/actions/artifact-transfer/index.mjs")],
                                       env=env, capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 17, completed.stderr)
            payload = json.loads(result.read_text())
            self.assertEqual(payload["runtime"], "test-runtime-token")
            self.assertEqual(payload["arguments"][1:], ["upload", "--name", "literal $(command)"])

    def test_sigterm_unwinds_and_retains_failed_receipt(self):
        previous = signal.getsignal(signal.SIGTERM)
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                "GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "secret", "GITHUB_RUN_ID": "10"}):
            source = Path(temporary) / "evidence.txt"
            source.write_text("original job files")
            receipt = Path(temporary) / "transfer.json"
            with patch.object(transfer, "upload_prepared", side_effect=lambda *args, **kwargs: os.kill(os.getpid(), signal.SIGTERM)):
                code = transfer.main(["upload", "--name", "evidence", "--path", str(source), "--receipt", str(receipt)])
            report = json.loads(receipt.read_text())
            self.assertEqual(code, 1)
            self.assertEqual(report["error"], "artifact transfer cancelled")
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous)
            self.assertEqual(source.read_text(), "original job files")

    def test_failed_upload_retains_terminal_summary_in_logs(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            output = io.StringIO()
            with redirect_stdout(output):
                code = transfer.main(["upload", "--name", "evidence", "--path", "missing",
                                      "--receipt", str(Path(temporary) / "transfer.json")])
            summary = json.loads(output.getvalue())
            self.assertEqual(code, 1)
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["operation"], "upload")
            self.assertIn("Evidence incomplete", summary["recovery"])
            self.assertNotIn("token=", output.getvalue())

    @unittest.skipUnless(shutil.which("node") and (Path(transfer.__file__).parent / "artifact-sdk/node_modules/@actions/artifact").is_dir(),
                         "Install the pinned artifact SDK to execute protocol fault tests")
    def test_actual_sdk_single_rpc_attempt_classifies_auth_and_service_failure(self):
        sdk = Path(transfer.__file__).parent / "artifact-sdk"
        cases = [(401, "permanent", b'{"code":"denied"}'),
                 (503, "transient", b'{"code":"unavailable"}'),
                 (502, "transient", b'<html>upstream unavailable</html>'),
                 (503, "transient", b'<html>upstream unavailable</html>'),
                 (200, "permanent", b'<html>invalid protocol</html>')]
        for status, classification, body in cases:
            class Handler(http.server.BaseHTTPRequestHandler):
                calls = 0
                def do_POST(self):
                    type(self).calls += 1
                    self.rfile.read(int(self.headers["Content-Length"]))
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(body)
                def log_message(self, *_args):
                    pass
            with self.subTest(status=status), http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    with tempfile.TemporaryDirectory() as temporary:
                        directory = Path(temporary)
                        source = directory / "payload.zip"
                        source.write_bytes(zip_bytes())
                        request, response = directory / "input.json", directory / "result.json"
                        request.write_text(json.dumps({"name": "fault-t1", "path": str(source),
                            "sha256": transfer.sha256_file(source), "retentionDays": 2}))
                        claims = base64.urlsafe_b64encode(b'{"scp":"Actions.Results:test-run:test-job"}').decode().rstrip("=")
                        env = {**os.environ, "ACTIONS_RUNTIME_TOKEN": "e30." + claims + ".signature",
                               "ACTIONS_RESULTS_URL": f"http://127.0.0.1:{server.server_port}"}
                        completed = subprocess.run([shutil.which("node"), str(sdk / "upload.mjs"), str(request), str(response)],
                                                   env=env, capture_output=True, timeout=10)
                        self.assertEqual(completed.returncode, 1, completed.stderr)
                        self.assertEqual(Handler.calls, 1)
                        error = json.loads(response.read_text())["error"]
                        self.assertEqual(error["category"], classification)
                        self.assertEqual(error["phase"], "create")
                        self.assertEqual(error["status"], status if status != 200 else None)
                finally:
                    server.shutdown()
                    thread.join(timeout=2)

    @unittest.skipUnless(shutil.which("node") and (Path(transfer.__file__).parent / "artifact-sdk/node_modules/@actions/artifact").is_dir(),
                         "Install the pinned artifact SDK to execute protocol success tests")
    def test_actual_sdk_upload_success_preserves_zip_bytes_and_finalize_provenance(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            rpc = []
            blocks = {}
            committed = None
            commits = 0
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                type(self).rpc.append((self.path.rsplit("/", 1)[1], request))
                if self.path.endswith("CreateArtifact"):
                    response = {"ok": True, "signedUploadUrl":
                                f"http://127.0.0.1:{self.server.server_port}/container/blob"}
                else:
                    response = {"ok": True, "artifactId": "42"}
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())
            def do_PUT(self):
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if query.get("comp") == ["block"]:
                    type(self).blocks[query["blockid"][0]] = body
                elif query.get("comp") == ["blocklist"]:
                    identifiers = [element.text for element in ET.fromstring(body)]
                    type(self).committed = b"".join(type(self).blocks[identity] for identity in identifiers)
                    type(self).commits += 1
                else:
                    type(self).committed = body
                    type(self).commits += 1
                self.send_response(201)
                self.send_header("Content-Length", "0")
                self.end_headers()
            def log_message(self, *_args):
                pass
        sdk = Path(transfer.__file__).parent / "artifact-sdk"
        with transfer.wall_deadline(10), http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    source = directory / "payload.zip"
                    # Larger than the adapter's 8 MiB single-shot limit exercises
                    # two real Azure block requests and the ordered block commit.
                    payload = zip_bytes("root.tar.gz", b"compiled native bytes\0" * (450 * 1024))
                    source.write_bytes(payload)
                    digest = transfer.sha256_file(source)
                    request, response = directory / "input.json", directory / "result.json"
                    request.write_text(json.dumps({"name": "compiled-t1", "path": str(source),
                        "sha256": digest, "retentionDays": 2}))
                    claims = base64.urlsafe_b64encode(b'{"scp":"Actions.Results:test-run:test-job"}').decode().rstrip("=")
                    env = {**os.environ, "ACTIONS_RUNTIME_TOKEN": "e30." + claims + ".signature",
                           "ACTIONS_RESULTS_URL": f"http://127.0.0.1:{server.server_port}"}
                    started = datetime.now(timezone.utc)
                    completed = subprocess.run([shutil.which("node"), str(sdk / "upload.mjs"), str(request), str(response)],
                                               env=env, capture_output=True, timeout=7)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertEqual(json.loads(response.read_text()), {"id": "42", "digest": "sha256:" + digest})
                    self.assertEqual(Handler.committed, payload)
                    self.assertEqual(len(Handler.blocks), 2)
                    self.assertEqual(Handler.commits, 1)
                    self.assertEqual([method for method, _ in Handler.rpc], ["CreateArtifact", "FinalizeArtifact"])
                    create, finalize = [request for _, request in Handler.rpc]
                    self.assertEqual(create["version"], 7)
                    self.assertEqual(create["mime_type"], "application/zip")
                    expires = datetime.fromisoformat(create["expires_at"].replace("Z", "+00:00"))
                    self.assertLess(abs((expires - started - timedelta(days=2)).total_seconds()), 10)
                    self.assertEqual(finalize["hash"], "sha256:" + digest)
                    self.assertEqual(finalize["size"], str(len(payload)))
                    for record in (create, finalize):
                        self.assertEqual(record["name"], "compiled-t1")
                        self.assertEqual(record["workflow_run_backend_id"], "test-run")
                        self.assertEqual(record["workflow_job_run_backend_id"], "test-job")
            finally:
                server.shutdown()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
