#!/usr/bin/env python3
# File: Tools/ci/github_release.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Prepare and publish a manually versioned release from a certified Git commit."""

import argparse
from copy import deepcopy
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, build_opener, urlopen

from teamcity_release import BUILD_NUMBER_PATTERN, RejectRedirects, TeamCityCertification


GITHUB_REPOSITORY = "Aurum-Studios/DiscordKit"
GITHUB_API = "https://api.github.com"
GITHUB_UPLOADS = "https://uploads.github.com"
VERSION_COMPONENT = r"(?:0|[1-9][0-9]*)"
TWO_COMPONENT_VERSION = rf"{VERSION_COMPONENT}\.{VERSION_COMPONENT}"
THREE_COMPONENT_VERSION = rf"{TWO_COMPONENT_VERSION}\.{VERSION_COMPONENT}"
BASE_VERSION_PATTERN = rf"(?:{THREE_COMPONENT_VERSION}|{TWO_COMPONENT_VERSION})"


def validate_inputs(version, revision):
    """Validate a promoted or legacy packaged version and its immutable full SHA."""
    if not re.fullmatch(rf"(?:{THREE_COMPONENT_VERSION}|{BASE_VERSION_PATTERN}\+{BUILD_NUMBER_PATTERN})", version):
        raise ValueError("Expected a promoted version such as 1.2+37 or a legacy version such as 1.2.37")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise ValueError("Commit must be a full 40-character Git commit SHA")
    return version, revision.lower()


def release_version(base, build_number):
    """Append the selected certification number to a canonical two- or three-part version."""
    base = base.removeprefix("v")
    if not re.fullmatch(BASE_VERSION_PATTERN, base):
        raise ValueError("Enter a release version such as 1.2 or 1.2.3")
    if not isinstance(build_number, str) or not re.fullmatch(BUILD_NUMBER_PATTERN, build_number):
        raise ValueError("Invalid TeamCity certification build number")
    return f"{base}+{build_number}"


def release_asset_name(version):
    """Use GitHub-safe filenames while preserving the build metadata in the tag and manifest."""
    return f"DiscordKit-{version.replace('+', '-build.')}-source"


class GitHubAPI:
    """Authenticate GitHub requests and distinguish missing resources from API failures."""

    def __init__(self, *, teamcity=False, allow_anonymous=False):
        """Bind TeamCity requests to DiscordKit and to its build-provided GitHub token."""
        self.repository = os.environ["GITHUB_REPOSITORY"]
        self.base = os.environ.get("GITHUB_API_URL", GITHUB_API).rstrip("/")
        self.token = os.environ.get("GH_TOKEN", "").strip() if teamcity else os.environ["GH_TOKEN"]
        self.write_token = self.token if teamcity else os.environ.get("RELEASE_TOKEN") or self.token
        self.open = None
        if teamcity:
            if self.repository != GITHUB_REPOSITORY or self.base != GITHUB_API:
                raise ValueError("TeamCity release requires the Aurum-Studios/DiscordKit GitHub repository")
            if not allow_anonymous and not self.token:
                raise ValueError("A build-scoped GitHub release credential is required")
            self.open = build_opener(RejectRedirects()).open

    def headers(self, token, content_type):
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": content_type,
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    def request(self, path, data=None, missing_ok=False, method=None):
        """Send a repository API request using the write credential for JSON mutations."""
        token = self.write_token if data is not None else self.token
        url = f"{self.base}/repos/{self.repository}"
        request = Request(
            f"{url}/{path}" if path else url,
            data=json.dumps(data).encode() if data is not None else None,
            headers=self.headers(token, "application/json"),
            method=method,
        )
        return self.send(request, path, missing_ok=missing_ok)

    def send(self, request, path, *, missing_ok=False, timeout=60):
        """Decode the response and give TeamCity reads two retries on DNS errors."""
        method = request.get_method()
        attempts = 3 if self.open is not None and method == "GET" else 1
        endpoint = path or "(repository metadata)"
        for attempt in range(1, attempts + 1):
            # The urllib proxy handler can rewrite the request in place.
            attempt_request = deepcopy(request) if attempts > 1 else request
            try:
                with (self.open or urlopen)(attempt_request, timeout=timeout) as response:
                    return json.load(response)
            except HTTPError as error:
                if missing_ok and error.code == 404:
                    return None
                raise RuntimeError(f"GitHub API {method} {endpoint} failed (HTTP {error.code})") from None
            except URLError as error:
                if self.open is None or not isinstance(error.reason, socket.gaierror):
                    raise
                message = (f"GitHub API {method} {endpoint} failed during DNS lookup for "
                           f"{attempt_request.host}: {error.reason}")
                if attempt == attempts:
                    raise RuntimeError(message) from None
                print(f"{message}. Retrying in {attempt}s.", file=sys.stderr)
                time.sleep(attempt)

    def upload(self, release_id, asset, content_type):
        """Stream a prepared asset to the GitHub release using the write credential."""
        headers = self.headers(self.write_token, content_type)
        headers["Content-Length"] = str(asset.stat().st_size)
        path = f"releases/{release_id}/assets"
        with asset.open("rb") as content:
            return self.send(Request(
                f"{GITHUB_UPLOADS}/repos/{self.repository}/{path}?{urlencode({'name': asset.name})}",
                data=content, headers=headers, method="POST"),
                path, timeout=600)


def require_commit(repository, revision):
    kind = subprocess.check_output(["git", "-C", str(repository), "cat-file", "-t", revision], text=True).strip()
    if kind != "commit":
        raise ValueError("Release commit must identify a commit in this repository")


def require_github_default_branch(api, branch, revision):
    """Authenticate the configured repository and check current default-branch membership."""
    repository = api.request("")
    if repository.get("full_name") != GITHUB_REPOSITORY or repository.get("default_branch") != branch:
        raise ValueError("GitHub repository or default branch does not match TeamCity settings")
    ref = api.request(f"git/ref/heads/{quote(branch, safe='/')}")
    tip = (ref.get("object") or {}).get("sha", "")
    if (ref.get("ref") != f"refs/heads/{branch}" or (ref.get("object") or {}).get("type") != "commit"
            or not re.fullmatch(r"[0-9a-f]{40}", tip)):
        raise ValueError("GitHub did not return the expected default Git branch")
    if tip == revision:
        return
    comparison = api.request(f"compare/{revision}...{tip}?per_page=1")
    if comparison.get("status") != "ahead" or (comparison.get("merge_base_commit") or {}).get("sha") != revision:
        raise ValueError("The selected commit is no longer on GitHub's default branch")


def certified_run(run, repository, revision):
    """Identify an archived GitHub Actions certification for evidence audits."""
    return (run.get("head_sha") == revision
            and run.get("status") == "completed" and run.get("conclusion") == "success"
            and run.get("event") in {"push", "workflow_dispatch"}
            and (run.get("head_repository") or {}).get("full_name", "").lower() == repository.lower())


def certification_gate_passed(api, run):
    """Require the full coverage barrier from the run's current attempt.

    Scoped final jobs have distinct names and cannot supersede full certification.
    The full-named job must actually finish its scope/coverage validation step;
    a legacy barrier, skipped validation, or partial rerun cannot qualify a release.
    """
    gates = []
    page = 1
    while True:
        jobs = api.request(
            f"actions/runs/{int(run['id'])}/attempts/{int(run['run_attempt'])}/jobs"
            f"?per_page=100&page={page}")["jobs"]
        gates.extend(job for job in jobs if job.get("name") == "Offline certification passed")
        if len(jobs) < 100:
            break
        page += 1
    if (len(gates) != 1
            or gates[0].get("run_id") != run["id"]
            or gates[0].get("head_sha") != run["head_sha"]
            or gates[0].get("status") != "completed"
            or gates[0].get("conclusion") != "success"):
        return False
    coverage = [step for step in gates[0].get("steps", [])
                if step.get("name") == "Verify full scope and complete coverage"]
    return (len(coverage) == 1
            and coverage[0].get("status") == "completed"
            and coverage[0].get("conclusion") == "success")


def successful_ci(api, revision):
    """Read historical GitHub Actions certification records for a revision."""
    for page in range(1, 11):
        runs = api.request(f"actions/workflows/ci.yml/runs?head_sha={revision}&per_page=100&page={page}")["workflow_runs"]
        for run in runs:
            if certified_run(run, api.repository, revision) and certification_gate_passed(api, run):
                return run
        if len(runs) < 100:
            break
    raise ValueError("No successful Offline certification (ci.yml) push/manual run with its final "
                     "'Offline certification passed' gate and verified full coverage for this exact commit; run CI first")


def require_unused_version(api, version):
    """Refuse both existing tags and releases, including unpublished drafts."""
    tag = f"v{version}"
    if api.request(f"git/ref/tags/{quote(tag, safe='')}", missing_ok=True) is not None:
        raise ValueError(f"Tag {tag} already exists; select a new version")
    page = 1
    while True:
        releases = api.request(f"releases?per_page=100&page={page}")
        if any(release["tag_name"] == tag for release in releases):
            raise ValueError(f"Release {tag} already exists; inspect any partial release before retrying")
        if len(releases) < 100:
            return
        page += 1


def prepare(repository, output, base_version, api, teamcity):
    """Produce the immutable source assets with read-only GitHub access."""
    from package_release import package_release

    run = teamcity.promoted(repository, "DiscordKit_PrepareRelease")
    version = release_version(base_version, run["number"])
    revision = run["head_sha"]
    require_commit(repository, revision)
    require_github_default_branch(api, teamcity.branch, revision)
    require_unused_version(api, version)
    assets = package_release(repository, output, version, revision, run)
    print(f"Prepared v{version} from {revision}; certification: {run['html_url']}")
    return assets


def verify_assets(output, version, revision):
    """Recheck downloaded bytes and metadata before granting them a release tag."""
    name = release_asset_name(version)
    archive = output / f"{name}.tar.gz"
    checksum = output / f"{name}.tar.gz.sha256"
    manifest = output / f"{name}.json"
    metadata = json.loads(manifest.read_text())
    evidence = metadata["ciRun"]
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    schema = 2 if evidence.get("provider") == "teamcity" else 1
    expected = {"schemaVersion": schema, "format": "swiftpm-source", "version": version,
                "tag": f"v{version}", "revision": revision, "archive": archive.name, "sha256": digest}
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError("Release manifest does not match the requested version, commit or archive bytes")
    if checksum.read_text() != f"{digest}  {archive.name}\n":
        raise ValueError("Release archive checksum does not match")
    return (archive, checksum, manifest), evidence


def publish(repository, output, base_version, api, teamcity):
    """Create a new exact tag and release, never editing or replacing existing ones."""
    run = teamcity.promoted(repository, "DiscordKit_PublishGitHubRelease")
    version = release_version(base_version, run["number"])
    revision = run["head_sha"]
    require_commit(repository, revision)
    require_github_default_branch(api, teamcity.branch, revision)
    assets, evidence = verify_assets(output, version, revision)
    if evidence != run:
        raise ValueError("Recorded TeamCity certification is no longer valid")
    publish_teamcity_release(api, version, revision, assets, evidence)


def require_exact_tag(api, tag, revision):
    ref = api.request(f"git/ref/tags/{quote(tag, safe='')}")
    if (ref.get("ref") != f"refs/tags/{tag}" or ref["object"].get("type") != "commit"
            or ref["object"].get("sha") != revision):
        raise ValueError("Release tag no longer points to the packaged commit")


def require_release_identity(release, expected, *, draft):
    release_id = release.get("id")
    if (type(release_id) is not int or release_id < 1 or release.get("draft") is not draft
            or release.get("prerelease") is not False
            or any(release.get(key) != expected[key] for key in ("tag_name", "name"))):
        raise ValueError("GitHub did not confirm the requested release state")
    return release_id


def require_uploaded_assets(api, release_id, expected):
    assets = api.request(f"releases/{release_id}/assets?per_page=100")
    if len(assets) != len(expected):
        raise ValueError("GitHub release asset inventory differs from the prepared assets")
    for asset in assets:
        if asset.get("state") != "uploaded":
            raise ValueError("GitHub did not complete a release asset upload")
    actual = {asset.get("name"): (asset.get("size"), asset.get("digest")) for asset in assets}
    if actual != expected:
        raise ValueError("GitHub did not verify the release asset checksums")


def publish_teamcity_release(api, version, revision, assets, evidence):
    """Publish a new release only after GitHub confirms every staged upload."""
    tag = f"v{version}"
    expected_assets = {}
    for asset in assets:
        with asset.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        expected_assets[asset.name] = (asset.stat().st_size, f"sha256:{digest}")
    require_unused_version(api, version)
    # Ref creation is atomic. A subsequent failure leaves the tag or draft for review.
    api.request("git/refs", {"ref": f"refs/tags/{tag}", "sha": revision})
    require_exact_tag(api, tag, revision)
    spec = {
        "tag_name": tag,
        "target_commitish": revision,
        "name": f"DiscordKit {version}",
        "body": (f"SwiftPM source distribution for DiscordKit {version}.\n\n"
                 f"Commit: `{revision}`\n\n"
                 f"Offline certification: {evidence['html_url']}.\n\n"
                 "Assets include the full source tree, SHA-256 checksum and provenance manifest. "
                 "Build the package with Swift 6.4 or newer."),
        "draft": True,
        "prerelease": False,
        "generate_release_notes": True,
    }
    draft = api.request("releases", spec)
    release_id = require_release_identity(draft, spec, draft=True)
    release_path = f"releases/{release_id}"
    expected_upload = f"{GITHUB_UPLOADS}/repos/{api.repository}/{release_path}/assets{{?name,label}}"
    if draft.get("upload_url") != expected_upload:
        raise ValueError("GitHub returned an unexpected release asset upload endpoint")
    for asset, content_type in zip(assets, ("application/gzip", "text/plain", "application/json")):
        api.upload(release_id, asset, content_type)
    require_uploaded_assets(api, release_id, expected_assets)
    require_exact_tag(api, tag, revision)
    require_github_default_branch(api, evidence["branch"], revision)
    if require_release_identity(api.request(release_path), spec, draft=True) != release_id:
        raise ValueError("GitHub returned a different draft")
    api.request(release_path, {"draft": False, "make_latest": "true"}, method="PATCH")
    published = api.request(release_path)
    if require_release_identity(published, spec, draft=False) != release_id:
        raise ValueError("GitHub returned a different release")
    require_uploaded_assets(api, release_id, expected_assets)
    require_exact_tag(api, tag, revision)
    print(f"Published https://github.com/{api.repository}/releases/tag/{quote(tag, safe='')} from {revision}")


def main():
    """Prepare or publish the selected TeamCity certification using the requested base version."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("prepare", "publish"))
    parser.add_argument("--repository", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    action = prepare if arguments.stage == "prepare" else publish
    teamcity = TeamCityCertification()
    api = GitHubAPI(teamcity=True, allow_anonymous=arguments.stage == "prepare")
    action(arguments.repository.resolve(), arguments.output.resolve(),
           arguments.version, api, teamcity)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)
