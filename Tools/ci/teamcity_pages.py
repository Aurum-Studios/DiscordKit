#!/usr/bin/env python3
# File: Tools/ci/teamcity_pages.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Publish certified DiscordKit documentation to the GitHub Pages branch."""

import argparse
from contextlib import suppress
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

import build_documentation_site
import documentation_inputs
import documentation_publication
import native_jobs
import native_receipts
import teamcity_artifact_transport


REMOTE = "https://github.com/Aurum-Studios/DiscordKit.git"
SOURCE_REF = "refs/heads/main"
PAGES_REF = "refs/heads/gh-pages"
INPUTS = Path(".build/teamcity/in")
DOCC_BUNDLE = build_documentation_site.ARCHIVE
DOCC_TAR = DOCC_BUNDLE + ".tar.gz"
DOCC_PARTS = DOCC_TAR.replace(".", "-") + "-parts"
DOCC_DIGEST = "documentationArchiveSHA256"
SITE_DIGEST = "documentationSiteSHA256"
MAX_RECEIPT_BYTES = 16 * 1024
ASKPASS = """#!/bin/sh
case "$1" in
    Username*) printf '%s\\n' 'x-access-token' ;;
    Password*) printf '%s\\n' "$DISCORDKIT_PAGES_GIT_TOKEN" ;;
    *) exit 1 ;;
esac
"""


def validate_certification(path, revision, build_id):
    """Require the matching successful certification received from this chain."""
    if (not native_receipts.SHA1.fullmatch(revision) or not re.fullmatch(r"[1-9][0-9]*", build_id)
            or path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_RECEIPT_BYTES):
        raise ValueError("Pages publication requires a valid revision and same-chain certification receipt")
    with path.open() as stream:
        receipt = native_receipts.read_json(stream)
    if (not isinstance(receipt, dict) or type(receipt.get("schemaVersion")) is not int
            or receipt["schemaVersion"] != 1 or receipt.get("status") != "passed"
            or receipt.get("buildId") != build_id or receipt.get("revision") != revision):
        raise ValueError("Pages certification does not match the requested revision or build")
    digests = [receipt[key] for key in (DOCC_DIGEST, SITE_DIGEST) if key in receipt]
    if not digests or any(not isinstance(digest, str) or not native_receipts.SHA256.fullmatch(digest)
                          for digest in digests):
        raise ValueError("Pages certification requires a valid documentation archive digest")
    return receipt


def git(repository, operation, *arguments, remote_env=None, timeout=30):
    """Run Git without external configuration or credentials in arguments or logs."""
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_") and key not in ("GH_TOKEN", "GITHUB_TOKEN")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    if remote_env:
        environment.update(remote_env)
    command = ("git", "-C", str(repository), "-c", "credential.helper=", "-c", "http.followRedirects=false",
               "-c", "core.hooksPath=/dev/null", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true",
               operation, *map(str, arguments))
    with subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          stdin=subprocess.DEVNULL, text=True, start_new_session=True) as process:
        try:
            output, _ = process.communicate(timeout=timeout)
        except BaseException:
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            raise
        if process.returncode:
            raise RuntimeError(f"git {operation} failed with exit status {process.returncode}")
        return output.strip()


def checked_refs(repository, remote, credentials, revision):
    """Require current GitHub main and read the existing Pages tip, when present."""
    result = git(repository, "ls-remote", "--symref", remote, "HEAD", PAGES_REF, remote_env=credentials)
    fields = [line.split("\t") for line in result.splitlines()]
    if any(len(row) != 2 or row[1] not in ("HEAD", PAGES_REF) for row in fields):
        raise ValueError("GitHub returned invalid source or Pages branch identity")
    head = [value for value, ref in fields if ref == "HEAD"]
    if sorted(head) != sorted([f"ref: {SOURCE_REF}", revision]):
        raise ValueError("Pages publication requires the current GitHub default-branch revision on main")
    pages = [value for value, ref in fields if ref == PAGES_REF]
    if len(pages) > 1 or any(not native_receipts.SHA1.fullmatch(value) for value in pages):
        raise ValueError("GitHub returned invalid Pages branch identity")
    return pages[0] if pages else None


def stage_site(repository, site):
    """Build a clean Git tree containing only the validated site contents."""
    reserved = {".git", ".github", ".gitmodules", ".gitattributes", ".gitignore"}
    files, size = 0, 0
    for index, path in enumerate(site.rglob("*"), start=1):
        if (path.is_symlink() or not (path.is_dir() or path.is_file())
                or any(part.casefold() in reserved or any(ord(character) < 32 for character in part)
                       for part in path.relative_to(site).parts)):
            raise ValueError("Pages site contains a link, special file or reserved Git path")
        if path.is_file():
            files += 1
            size += path.stat().st_size
        if index > documentation_publication.MAX_SITE_MEMBERS or size > documentation_publication.MAX_SITE_BYTES:
            raise ValueError("Pages site exceeds its size or file count limit")
    git(repository, "init", "--quiet", "--initial-branch=gh-pages", "--template=")
    git(repository, "config", "user.name", "Aurum Studios CI")
    git(repository, "config", "user.email", "ci@aurum-studios.com")
    git(site, "--git-dir", repository / ".git", "add", "--all", "--force", "--", ".", timeout=120)
    return git(repository, "write-tree", timeout=120), {"files": files, "bytes": size}


def prepare_site(repository, archive, receipt, scratch, docc):
    """Verify the certified transport before extracting or transforming its contents."""
    native = DOCC_DIGEST in receipt
    if archive is None:
        inputs = repository / INPUTS
        if native:
            parts = inputs / DOCC_PARTS
            archive = parts if parts.exists() or parts.is_symlink() else inputs / DOCC_TAR
        else:
            archive = inputs / "documentation-site.tar.gz"
    sealed = scratch / "documentation.tar.gz"
    if archive.is_symlink():
        raise ValueError("Pages input archive must not be a symlink")
    if native and archive.is_dir():
        teamcity_artifact_transport.join(archive, sealed)
    elif archive.is_file():
        shutil.copyfile(archive, sealed)
    else:
        raise ValueError("Pages input archive is missing")
    if native_jobs.file_digest(sealed) != receipt[DOCC_DIGEST if native else SITE_DIGEST]:
        raise ValueError("Pages archive differs from its certification digest")

    site = scratch / "site"
    if not native:
        documentation_publication.extract_site(sealed, site)
        return site

    bundle = scratch / DOCC_BUNDLE
    documentation_publication.extract_bundle(sealed, bundle, root=DOCC_BUNDLE,
        required_files={"metadata.json"}, maximum_bytes=documentation_inputs.MAX_BYTES)
    environment = {key: value for key, value in os.environ.items()
                   if key not in ("GH_TOKEN", "GITHUB_TOKEN", "DISCORDKIT_PAGES_GIT_TOKEN")}
    docc = docc or shutil.which("docc")
    if not docc and shutil.which("xcrun"):
        docc = subprocess.check_output(["xcrun", "--find", "docc"], env=environment,
                                      text=True, timeout=30).strip()
    if not docc:
        raise ValueError("Select a Swift toolchain with DocC to transform the certified archive")
    subprocess.run([docc, "process-archive", "transform-for-static-hosting", bundle,
                    "--output-path", site, "--hosting-base-path", "/DiscordKit"],
                   env=environment, check=True, timeout=1200)
    landing = site / "documentation/index.html"
    if (site.is_symlink() or landing.parent.is_symlink() or landing.is_symlink() or not landing.is_file()
            or any((site / name).is_symlink() for name in ("index.html", ".nojekyll", build_documentation_site.MARKER))):
        raise ValueError("DocC did not produce a regular static documentation site")
    (site / "index.html").write_text(build_documentation_site.ROOT_REDIRECT)
    (site / ".nojekyll").touch()
    (site / build_documentation_site.MARKER).write_text(build_documentation_site.MARKER_CONTENT)
    return site


def publish(repository, archive, certification, revision, build_id, token, *, remote=REMOTE, docc=None):
    """Create an ordinary fast-forward commit from the hosted, certified site."""
    receipt = validate_certification(certification, revision, build_id)
    if not token or any(character.isspace() for character in token):
        raise ValueError("Pages publication requires GH_TOKEN")
    if git(repository, "rev-parse", "HEAD") != revision or git(repository, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Pages publication checkout differs from the clean certified revision")
    with tempfile.TemporaryDirectory(prefix="discordkit-pages-") as temporary:
        scratch = Path(temporary).resolve()
        askpass = scratch / "askpass"
        askpass.write_text(ASKPASS)
        askpass.chmod(0o700)
        credentials = {"GIT_ASKPASS": str(askpass), "DISCORDKIT_PAGES_GIT_TOKEN": token}
        site = prepare_site(repository, archive, receipt, scratch, docc)
        staging = scratch / "repository"
        staging.mkdir()
        tree, site_summary = stage_site(staging, site)
        previous = checked_refs(staging, remote, credentials, revision)
        parent_arguments = []
        previous_tree = None
        if previous:
            git(staging, "fetch", "--quiet", "--no-tags", "--depth=1", remote, PAGES_REF,
                remote_env=credentials, timeout=120)
            if git(staging, "rev-parse", "FETCH_HEAD") != previous:
                raise ValueError("GitHub Pages changed during publication preparation")
            previous_tree = git(staging, "rev-parse", f"{previous}^{{tree}}")
            parent_arguments = ["-p", previous]
        if tree == previous_tree:
            result = {"status": "unchanged", "pagesCommit": previous}
        else:
            commit = git(staging, "commit-tree", tree, *parent_arguments, "-m",
                         f"Publish DiscordKit documentation for {revision}")
            result = {"status": "published", "pagesCommit": commit}
        if checked_refs(staging, remote, credentials, revision) != previous:
            raise ValueError("GitHub Pages changed before publication")
        if result["status"] == "published":
            git(staging, "push", "--quiet", remote, f"{result['pagesCommit']}:{PAGES_REF}",
                remote_env=credentials, timeout=120)
        return {"schemaVersion": 1, "revision": revision, "certificationBuildId": build_id,
                "site": site_summary, **result}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path("."))
    parser.add_argument("--archive", type=Path, help="certified DocC archive or its TeamCity parts directory")
    parser.add_argument("--certification", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--docc", help="DocC executable for transforming a certified native archive")
    args = parser.parse_args(argv)
    repository = args.repository.resolve()
    certification = args.certification or repository / INPUTS / "certification.json"
    output = args.output or repository / ".build/teamcity/out/pages-publication.json"
    try:
        report = publish(repository, args.archive, certification, os.environ.get("DISCORDKIT_VCS_REVISION", ""),
                         os.environ.get("DISCORDKIT_CERTIFICATION_ID", ""), os.environ.get("GH_TOKEN", ""),
                         docc=args.docc)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        report = {"schemaVersion": 1, "status": "failed", "error": str(error)}
    native_jobs.write_json(output, report)
    print(json.dumps(report, sort_keys=True))
    return int(report["status"] == "failed")


if __name__ == "__main__":
    sys.exit(main())
