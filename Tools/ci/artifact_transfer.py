#!/usr/bin/env python3
# File: Tools/ci/artifact_transfer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Bounded immutable GitHub artifact transport; never starts a compiler or test.

The REST API's digest seals its outer ZIP. Native tar admission remains the job
helper's responsibility. Every candidate uploads the same prepared ZIP bytes.
"""

import argparse
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import socket
import ssl
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import native_receipts


MAX_ATTEMPTS = 3
ATTEMPT_SECONDS = 120
AGGREGATE_SECONDS = 420
TRANSIENT_STATUS = {408, 429, 500, 502, 503, 504}
TRANSIENT_ERRNO = {32, 54, 60, 61, 104, 110, 111}
SHA256 = re.compile(r"sha256:[0-9a-f]{64}")
MAX_JSON = 16 * 1024 * 1024
MAX_ZIP_BYTES = 32 * 1024 * 1024 * 1024


class TransferError(ValueError):
    """Only an explicitly transient transport failure permits another attempt."""

    def __init__(self, message, *, transient=False):
        super().__init__(message)
        self.transient = transient


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class Budget:
    """Share one monotonic budget through transfer, reconciliation and readback."""

    def __init__(self, seconds=AGGREGATE_SECONDS):
        self.started = time.monotonic()
        self.deadline = self.started + min(seconds, AGGREGATE_SECONDS)

    def remaining(self, deadline=None):
        remaining = min(self.deadline, deadline or self.deadline) - time.monotonic()
        if remaining <= 0:
            raise TransferError("artifact transport deadline exhausted", transient=True)
        return remaining


@contextmanager
def wall_deadline(seconds):
    """Interrupt stalled/trickling REST reads, including DNS, at a wall deadline.

    Hosted native jobs run Python on Unix in the main thread. Fail closed when
    that supervision primitive is unavailable instead of falling back to a socket
    inactivity timeout that can run forever while a peer trickles bytes.
    """
    if not hasattr(signal, "setitimer"):
        raise TransferError("artifact REST transport requires Unix wall deadline support")
    def expired(_number, _frame):
        raise TransferError("artifact transport attempt timed out", transient=True)
    previous = signal.signal(signal.SIGALRM, expired)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()
    signal.setitimer(signal.ITIMER_REAL, min(seconds, previous_timer[0]) if previous_timer[0] else seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, max(0.000001, previous_timer[0] - (time.monotonic() - started))
                         if previous_timer[0] else 0, previous_timer[1])
        signal.signal(signal.SIGALRM, previous)


def recover(operation, *, budget=None, attempts=None, description="transfer"):
    """Run up to three classified attempts and retain every terminal result."""
    budget = budget or Budget()
    attempts = attempts if attempts is not None else []
    for number in range(1, MAX_ATTEMPTS + 1):
        started = time.monotonic()
        deadline = min(budget.deadline, started + ATTEMPT_SECONDS)
        record = {"operation": description, "attempt": number, "limitSeconds": ATTEMPT_SECONDS}
        attempts.append(record)
        try:
            budget.remaining(deadline)
            with wall_deadline(budget.remaining(deadline)):
                result = operation(number, deadline)
            budget.remaining(deadline)
            record.update(result="verified", elapsedSeconds=round(time.monotonic() - started, 6))
            return result
        except TransferError as error:
            record.update(result="failed", classification="transient" if error.transient else "permanent",
                          error=str(error), elapsedSeconds=round(time.monotonic() - started, 6))
            if not error.transient or number == MAX_ATTEMPTS:
                raise
            budget.remaining()
    raise AssertionError("unreachable transfer state")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep GitHub credentials out of signed storage redirects."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHubArtifactClient:
    """Authenticated API metadata and digest-verified immutable artifact reads."""

    def __init__(self, repository, token, run_id, *, api_url=None):
        if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or not re.fullmatch(r"[1-9][0-9]*", str(run_id)) or not token):
            raise TransferError("complete GitHub repository/run/token is required")
        self.repository, self.token, self.run_id = repository, token, str(run_id)
        self.api_url = (api_url or os.environ.get("GITHUB_API_URL", "https://api.github.com")).rstrip("/")
        if urllib.parse.urlparse(self.api_url).scheme != "https":
            raise TransferError("GitHub API must use HTTPS")
        self.budget = None
        self.deadline = None
        self.attempts = []

    @property
    def base(self):
        return f"/repos/{self.repository}/actions"

    @contextmanager
    def within(self, budget, deadline):
        old = self.budget, self.deadline
        self.budget, self.deadline = budget, deadline
        try:
            yield
        finally:
            self.budget, self.deadline = old

    def _request(self, path, *, redirect=False, maximum=MAX_JSON, output=None):
        url = self.api_url + path
        authenticated = True
        budget = self.budget or Budget()
        deadline = self.deadline or min(budget.deadline, time.monotonic() + ATTEMPT_SECONDS)
        try:
            with wall_deadline(budget.remaining(deadline)):
                for _ in range(5):
                    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
                    if authenticated:
                        headers["Authorization"] = f"Bearer {self.token}"
                    request = urllib.request.Request(url, headers=headers)
                    try:
                        response = urllib.request.build_opener(NoRedirect()).open(
                            request, timeout=budget.remaining(deadline))
                    except urllib.error.HTTPError as error:
                        if redirect and error.code in (301, 302, 303, 307, 308):
                            location = urllib.parse.urljoin(url, error.headers.get("Location", ""))
                            error.close()
                            if urllib.parse.urlparse(location).scheme != "https":
                                raise TransferError("unsafe artifact storage redirect")
                            url, authenticated = location, False
                            continue
                        error.close()
                        raise TransferError(f"GitHub artifact HTTP {error.code}", transient=error.code in TRANSIENT_STATUS)
                    with response:
                        if output is not None:
                            size = 0
                            with Path(output).open("wb") as stream:
                                while chunk := response.read(1024 * 1024):
                                    size += len(chunk)
                                    if size > maximum:
                                        raise TransferError("artifact response exceeds size limit")
                                    stream.write(chunk)
                            return Path(output)
                        data = response.read(maximum + 1)
                        if len(data) > maximum:
                            raise TransferError("artifact response exceeds size limit")
                        return data
                raise TransferError("too many artifact storage redirects")
        except urllib.error.URLError as error:
            reason = error.reason
            transient = isinstance(reason, (TimeoutError, socket.timeout)) or getattr(reason, "errno", None) in TRANSIENT_ERRNO
            if isinstance(reason, ssl.SSLError):
                transient = False
            raise TransferError("artifact network transport failed", transient=transient) from None
        except (TimeoutError, socket.timeout):
            raise TransferError("artifact network timeout", transient=True) from None
        except OSError as error:
            raise TransferError("artifact network read failed", transient=(
                not isinstance(error, ssl.SSLError) and error.errno in TRANSIENT_ERRNO)) from None

    def _bounded(self, operation, description):
        if self.budget is not None:
            return operation()
        budget = Budget()
        def attempt(_number, deadline):
            with self.within(budget, deadline):
                return operation()
        return recover(attempt, budget=budget, attempts=self.attempts, description=description)

    def api_json(self, path):
        if not isinstance(path, str) or not path.startswith(self.base + "/") or "#" in path:
            raise TransferError("invalid artifact API path")
        def read():
            try:
                return native_receipts.read_json(io.StringIO(self._request(path).decode("utf8")))
            except (UnicodeError, ValueError) as error:
                if isinstance(error, TransferError):
                    raise
                raise TransferError("invalid artifact API JSON") from None
        return self._bounded(read, "metadata")

    def _list(self, path, key):
        def read():
            records = []
            expected, seen = None, set()
            for page in range(1, 1001):
                payload = self.api_json(f"{path}?per_page=100&page={page}")
                if (not isinstance(payload, dict) or not isinstance(payload.get(key), list)
                        or type(payload.get("total_count")) is not int or payload["total_count"] < 0
                        or len(payload[key]) > 100):
                    raise TransferError("invalid GitHub artifact listing")
                if expected is None:
                    expected = payload["total_count"]
                elif expected != payload["total_count"]:
                    raise TransferError("GitHub artifact listing changed during pagination", transient=True)
                for item in payload[key]:
                    if (not isinstance(item, dict) or type(item.get("id")) is not int
                            or item["id"] <= 0 or item["id"] in seen):
                        raise TransferError("invalid or duplicate GitHub listing identity")
                    seen.add(item["id"])
                records.extend(payload[key])
                if len(payload[key]) < 100:
                    if len(records) != expected:
                        raise TransferError("incomplete GitHub artifact listing snapshot", transient=True)
                    return records
            raise TransferError("GitHub artifact listing exceeds page limit")
        return self._bounded(read, "listing")

    def list_artifacts(self):
        return self._list(f"{self.base}/runs/{self.run_id}/artifacts", "artifacts")

    def list_jobs(self, attempt):
        if not re.fullmatch(r"[1-9][0-9]*", str(attempt)):
            raise TransferError("invalid producer attempt")
        return self._list(f"{self.base}/runs/{self.run_id}/attempts/{attempt}/jobs", "jobs")

    def get_run(self):
        return self.api_json(f"{self.base}/runs/{self.run_id}")

    def get_artifact(self, artifact_id):
        if not re.fullmatch(r"[1-9][0-9]*", str(artifact_id)):
            raise TransferError("immutable artifact ID must be a positive integer")
        return self.api_json(f"{self.base}/artifacts/{artifact_id}")

    def _download(self, artifact_id, expected_digest, output=None):
        if not re.fullmatch(r"[1-9][0-9]*", str(artifact_id)) or not SHA256.fullmatch(expected_digest):
            raise TransferError("immutable artifact ID and SHA256 digest are required")
        def read():
            artifact = self.get_artifact(artifact_id)
            if (str(artifact.get("id")) != str(artifact_id) or artifact.get("expired") is not False
                    or artifact.get("digest") != expected_digest):
                raise TransferError("artifact expired or API digest changed; schedule an explicit fresh build")
            if str(artifact.get("workflow_run", {}).get("id")) != self.run_id:
                raise TransferError("artifact belongs to a different workflow run")
            data = self._request(f"{self.base}/artifacts/{artifact_id}/zip", redirect=True,
                                 maximum=MAX_ZIP_BYTES if output else MAX_JSON, output=output)
            digest = sha256_file(data) if output else hashlib.sha256(data).hexdigest()
            if "sha256:" + digest != expected_digest:
                raise TransferError("artifact ZIP digest mismatch")
            return data
        return self._bounded(read, "download")

    def download_bytes(self, artifact_id, expected_digest):
        """Tiny index receipts only; large compiled ZIPs must stream to disk."""
        return self._download(artifact_id, expected_digest)

    def download_file(self, artifact_id, expected_digest, destination):
        return self._download(artifact_id, expected_digest, Path(destination))

    def read_zip_json(self, artifact_id, expected_digest, member):
        data = self.download_bytes(artifact_id, expected_digest)
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                validate_zip(archive)
                if len(archive.namelist()) != 1 or archive.namelist() != [member]:
                    raise TransferError("unexpected producer receipt ZIP members")
                if archive.getinfo(member).file_size > MAX_JSON:
                    raise TransferError("producer receipt exceeds size limit")
                return native_receipts.read_json(io.StringIO(archive.read(member).decode("utf8")))
        except (zipfile.BadZipFile, UnicodeError, ValueError) as error:
            if isinstance(error, TransferError):
                raise
            raise TransferError("invalid producer receipt ZIP/JSON") from None


def validate_zip(archive):
    """Check all outer ZIP members before writing any extracted file."""
    seen = set()
    expanded = 0
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        mode = info.external_attr >> 16
        if (not info.filename or "\\" in info.filename or "\0" in info.filename
                or path.is_absolute() or any(part in ("", ".", "..") for part in info.filename.split("/"))
                or str(path) != info.filename or info.filename in seen or info.is_dir()
                or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)) or info.flag_bits & 1):
            raise TransferError("unsafe artifact ZIP member")
        seen.add(info.filename)
        expanded += info.file_size
        if expanded > MAX_ZIP_BYTES:
            raise TransferError("artifact ZIP expansion exceeds size limit")
    if not seen:
        raise TransferError("empty artifact ZIP")


def extract_zip(data, destination):
    destination = Path(destination)
    try:
        with zipfile.ZipFile(io.BytesIO(data) if isinstance(data, bytes) else data) as archive:
            validate_zip(archive)
            # The transfer format is flat; evidence trees stay inside a tarball.
            if any("/" in name for name in archive.namelist()):
                raise TransferError("unexpected nested artifact ZIP member")
            destination.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink() or any(parent.is_symlink() for parent in destination.parents):
                raise TransferError("artifact destination has symlink ancestor")
            if any((destination / name).exists() or (destination / name).is_symlink() for name in archive.namelist()):
                raise TransferError("artifact extraction would overwrite a file")
            # CRC verification happens before extraction, in addition to API SHA256.
            if archive.testzip() is not None:
                raise TransferError("artifact ZIP CRC mismatch")
            # A deadline or failed stream cannot leave partial files in the restore
            # destination. Stage on the same filesystem; hardlink installation is
            # atomic per file and refuses to overwrite an intervening writer.
            with tempfile.TemporaryDirectory(prefix=".artifact-extract-", dir=destination.parent) as temporary:
                for info in archive.infolist():
                    with (Path(temporary) / info.filename).open("xb") as output, archive.open(info) as source:
                        while chunk := source.read(1024 * 1024):
                            output.write(chunk)
                for info in archive.infolist():
                    os.link(Path(temporary) / info.filename, destination / info.filename)
    except (zipfile.BadZipFile, RuntimeError) as error:
        raise TransferError("invalid artifact ZIP") from error


def prepare_zip(paths, output, *, evidence=False):
    paths = [Path(path) for path in paths]
    if not paths or any(not path.exists() for path in paths):
        raise TransferError("artifact input is missing; regenerate only the missing evidence explicitly")
    if evidence or any(path.is_dir() for path in paths):
        tar_path = Path(output).with_suffix(".tar.gz")
        common = Path(os.path.commonpath([str(path.resolve()) for path in paths]))
        if common.is_file():
            common = common.parent
        with tarfile.open(tar_path, "w:gz") as archive:
            for path in paths:
                archive.add(path, arcname=str(path.resolve().relative_to(common)) if path.resolve() != common else path.name)
        paths = [tar_path]
    if len({path.name for path in paths}) != len(paths):
        raise TransferError("ambiguous artifact basenames")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for path in sorted(paths):
            if not path.is_file() or path.is_symlink() or not re.fullmatch(r"[A-Za-z0-9_.-]+", path.name):
                raise TransferError("unsafe artifact input filename; use evidence tar packaging")
            archive.write(path, path.name)
    return sha256_file(output)


def upload_worker(name, path, digest, retention_days, deadline):
    """Supervise the official service/Blob SDK child, with retries disabled."""
    sdk = Path(__file__).resolve().parent / "artifact-sdk"
    with tempfile.TemporaryDirectory(prefix="artifact-worker-") as temporary:
        request, response = Path(temporary) / "input.json", Path(temporary) / "result.json"
        write_json(request, {"name": name, "path": str(Path(path).resolve()), "sha256": digest,
                             "retentionDays": retention_days})
        process = subprocess.Popen(["node", str(sdk / "upload.mjs"), str(request), str(response)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise TransferError("artifact upload attempt timed out", transient=True) from None
        finally:
            # Includes SIGALRM, cancellation and unexpected Python exceptions.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        if not response.is_file():
            raise TransferError("artifact upload worker failed without a terminal receipt")
        try:
            result = json.loads(response.read_text())
        except (ValueError, OSError):
            raise TransferError("invalid artifact worker receipt") from None
        if result.get("error"):
            error = result["error"]
            raise TransferError(f"artifact upload failed during {error.get('phase')} (HTTP {error.get('status')})",
                                transient=error.get("category") == "transient")
        if process.returncode != 0:
            raise TransferError("artifact upload worker exited unsuccessfully")
        return result


def upload_prepared(client, name, path, *, budget=None, attempts=None, retention_days=2):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or not 1 <= retention_days <= 90:
        raise TransferError("invalid immutable artifact name or retention")
    budget = budget or Budget()
    digest = "sha256:" + sha256_file(path)
    def attempt(number, deadline):
        candidate = f"{name}-t{number}"
        with client.within(budget, deadline):
            # Also reconciles a timeout after finalization or an interrupted caller.
            matches = [item for item in client.list_artifacts() if item.get("name") == candidate]
            if len(matches) > 1:
                raise TransferError("ambiguous immutable upload candidate")
            if matches:
                result = matches[0]
                if result.get("digest") != digest:
                    raise TransferError("existing immutable upload candidate digest mismatch")
            else:
                # A failed upload can have finalized remotely. A later attempt uses
                # a fresh name and unchanged bytes; no candidate is deleted/overwritten.
                result = upload_worker(candidate, path, digest[7:], retention_days, deadline)
            artifact = client.get_artifact(result["id"])
            if (artifact.get("name") != candidate or artifact.get("digest") != digest
                    or artifact.get("expired") is not False
                    or str(artifact.get("workflow_run", {}).get("id")) != client.run_id):
                raise TransferError("uploaded artifact identity/digest readback mismatch")
            return {"id": str(artifact["id"]), "name": candidate, "digest": digest}
    return recover(attempt, budget=budget, attempts=attempts, description="upload")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    upload = subparsers.add_parser("upload")
    upload.add_argument("--name", required=True)
    upload.add_argument("--path", action="append", required=True)
    upload.add_argument("--evidence", action="store_true")
    upload.add_argument("--retention-days", type=int, default=2)
    upload.add_argument("--producer-metadata")
    upload.add_argument("--producer-receipt-name")
    download = subparsers.add_parser("download")
    download.add_argument("--artifact-id", required=True)
    download.add_argument("--expected-digest", required=True)
    download.add_argument("--destination", required=True)
    for child in (upload, download):
        child.add_argument("--receipt", required=True)
    args = parser.parse_args(argv)
    report = {"formatVersion": 1, "operation": args.command, "status": "failed", "attempts": [],
              "limits": {"attempts": MAX_ATTEMPTS, "attemptSeconds": ATTEMPT_SECONDS,
                         "aggregateSeconds": AGGREGATE_SECONDS}, "startedAt": native_receipts.utc_now()}
    budget = Budget()
    def cancelled(_number, _frame):
        raise TransferError("artifact transfer cancelled")
    handlers = {number: signal.signal(number, cancelled) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        client = GitHubArtifactClient(os.environ.get("GITHUB_REPOSITORY", ""),
                                      os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""),
                                      os.environ.get("GITHUB_RUN_ID", ""))
        with wall_deadline(budget.remaining()):
            if args.command == "upload":
                if bool(args.producer_metadata) != bool(args.producer_receipt_name):
                    raise TransferError("producer metadata and receipt name must be supplied together")
                metadata, archive_digest = None, None
                if args.producer_metadata:
                    with Path(args.producer_metadata).open() as stream:
                        metadata = native_receipts.read_json(stream)
                    archive_digest = metadata.pop("archiveSHA256", None)
                    if not isinstance(archive_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", archive_digest):
                        raise TransferError("producer compilation receipt lacks archiveSHA256")
                    try:
                        native_receipts.validate_metadata(metadata, metadata["compatibility"],
                            metadata["producer"]["execution"], metadata["component"], metadata["buildRoots"])
                    except (KeyError, TypeError, ValueError):
                        raise TransferError("invalid producer compilation metadata") from None
                    if (len(args.path) != 1 or sha256_file(args.path[0]) != archive_digest
                            or args.evidence or not Path(args.path[0]).name.endswith(".tar.gz")):
                        raise TransferError("producer archive does not match compilation receipt")
                with tempfile.TemporaryDirectory(prefix="artifact-transfer-") as temporary:
                    prepared = Path(temporary) / "payload.zip"
                    prepare_zip(args.path, prepared, evidence=args.evidence)
                    report["artifact"] = upload_prepared(client, args.name, prepared, budget=budget,
                                                        attempts=report["attempts"], retention_days=args.retention_days)
                    if args.producer_metadata:
                        envelope = {"formatVersion": 1, "metadata": metadata,
                                    "artifact": {**report["artifact"], "archiveSHA256": archive_digest}}
                        receipt = Path(temporary) / "producer-receipt.json"
                        write_json(receipt, envelope)
                        prepared_receipt = Path(temporary) / "receipt.zip"
                        prepare_zip([receipt], prepared_receipt)
                        report["producerReceipt"] = upload_prepared(client, args.producer_receipt_name, prepared_receipt,
                            budget=budget, attempts=report["attempts"], retention_days=args.retention_days)
            else:
                def attempt(_number, deadline):
                    with client.within(budget, deadline):
                        with tempfile.TemporaryDirectory(prefix="artifact-download-") as temporary:
                            data = client.download_file(args.artifact_id, args.expected_digest, Path(temporary) / "payload.zip")
                            extract_zip(data, args.destination)
                        return {"id": args.artifact_id, "digest": args.expected_digest}
                report["artifact"] = recover(attempt, budget=budget, attempts=report["attempts"], description="download")
        report["status"] = "verified"
    except (TransferError, OSError, ValueError) as error:
        report["error"] = str(error)
        report["recovery"] = ("Evidence incomplete. Retry upload while original files remain; after runner disposal, "
                              "explicitly regenerate only the missing evidence/producer. No build or test was retried.")
        return 1
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)
        report["completedAt"] = native_receipts.utc_now()
        report["elapsedSeconds"] = round(time.monotonic() - budget.started, 6)
        try:
            write_json(args.receipt, report)
        finally:
            # Retain the sanitized terminal receipt in Actions logs even after the
            # runner's local files are disposed or every evidence upload fails.
            print(json.dumps(report, separators=(",", ":"), sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
