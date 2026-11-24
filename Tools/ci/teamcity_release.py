# File: Tools/ci/teamcity_release.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Use live TeamCity build evidence to admit a DiscordKit release."""

import hashlib
import json
import os
import re
import subprocess
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener


TEAMCITY_URL = "https://ci.aurum-studios.com"
CERTIFICATION_ID = "DiscordKit_Certification"
BUILD_FIELDS = (
    "id,number,buildTypeId,defaultBranch,state,status,personal,failedToStart,canceledInfo,"
    "revisions(revision(version,vcsBranchName,vcs-root-instance(vcs-root-id))),"
    "snapshot-dependencies(build(id,buildTypeId))"
)
BUILD_NUMBER_PATTERN = r"[1-9][0-9]*"


class RejectRedirects(HTTPRedirectHandler):
    """Avoid forwarding a credential to a redirect target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class TeamCityCertification:
    """Validate TeamCity state for the publish job and its candidate build."""

    def __init__(self):
        self.base = os.environ.get("TEAMCITY_URL", TEAMCITY_URL).rstrip("/")
        if self.base != TEAMCITY_URL:
            raise ValueError("The release requires ci.aurum-studios.com")
        self.token = os.environ["TEAMCITY_TOKEN"]
        if not self.token.strip():
            raise ValueError("A TeamCity build-results read credential is required")
        self.root = os.environ["TEAMCITY_VCS_ROOT_ID"]
        self.branch = os.environ["RELEASE_DEFAULT_BRANCH"]
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", self.root):
            raise ValueError("Invalid TeamCity VCS root ID")
        self.opener = build_opener(RejectRedirects())

    def request(self, path, *, raw=False, **query):
        url = f"{self.base}/app/rest/{path}"
        if query:
            url += f"?{urlencode(query)}"
        request = Request(url, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "*/*" if raw else "application/json",
        })
        try:
            with self.opener.open(request, timeout=30) as response:
                return response.read() if raw else json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"TeamCity build evidence request failed (HTTP {error.code})") from None

    def build(self, build_id):
        if type(build_id) is not int or build_id < 1:
            raise ValueError("Invalid TeamCity build ID")
        build = self.request(f"builds/id:{build_id}", fields=BUILD_FIELDS)
        if build.get("id") != build_id:
            raise ValueError("TeamCity returned a different build")
        return build

    def default_revision(self, build):
        """Return the exact default-branch commit for the configured root, if eligible."""
        revisions = (build.get("revisions") or {}).get("revision", [])
        matching = [
            item for item in revisions
            if (item.get("vcs-root-instance") or {}).get("vcs-root-id") == self.root
        ]
        if (build.get("defaultBranch") is True
                and not build.get("personal")
                and not build.get("canceledInfo")
                and len(matching) == 1
                and matching[0].get("vcsBranchName") == f"refs/heads/{self.branch}"):
            revision = matching[0].get("version")
            if isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision):
                return revision
        return None

    def require_current_checkout(self, repository, configuration_id):
        """Verify the running release job and return its build record and dependencies."""
        if os.environ.get("TEAMCITY_DEFAULT_BRANCH") != "true":
            raise ValueError("Run the release from the repository's default branch")
        build_id = os.environ["DISCORDKIT_CI_BUILD_ID"]
        if not re.fullmatch(r"[1-9][0-9]*", build_id):
            raise ValueError("Invalid current TeamCity build ID")
        build = self.build(int(build_id))
        head = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
        if (build.get("buildTypeId") != configuration_id
                or build.get("state") != "running" or self.default_revision(build) != head):
            raise ValueError("Release tooling must use the current TeamCity default-branch checkout")
        return build

    def evidence(self, build, revision):
        """Return the exact successful build's provenance after validating its sealed receipt."""
        if (build.get("buildTypeId") != CERTIFICATION_ID
                or build.get("state") != "finished"
                or build.get("status") != "SUCCESS"
                or build.get("failedToStart")
                or self.default_revision(build) != revision):
            return None
        build_id = build.get("id")
        if type(build_id) is not int or build_id < 1:
            raise ValueError("Invalid TeamCity certification build ID")
        number = build.get("number")
        if not isinstance(number, str) or not re.fullmatch(BUILD_NUMBER_PATTERN, number):
            raise ValueError("Invalid TeamCity certification build number")
        # Stream the receipt from TeamCity so the bearer-authenticated request stays on its origin.
        contents = self.request(f"builds/id:{build_id}/artifacts/content/certification.json",
                                raw=True, responseBuilder="core")
        receipt = json.loads(contents)
        prerequisites = receipt.get("prerequisites")
        doc_digest = receipt.get("documentationArchiveSHA256")
        if (receipt.get("schemaVersion") != 1 or receipt.get("status") != "passed"
                or receipt.get("buildId") != str(build_id) or receipt.get("revision") != revision
                or not isinstance(doc_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", doc_digest)
                or not isinstance(prerequisites, dict) or not prerequisites
                or any(not isinstance(item, str) or not re.fullmatch(r"[1-9][0-9]*", item)
                       or item == str(build_id) for item in prerequisites.values())
                or len(set(prerequisites.values())) != len(prerequisites)):
            raise ValueError("TeamCity certification did not produce complete coverage evidence")
        return {
            "provider": "teamcity",
            "id": build_id,
            "number": number,
            "buildTypeId": CERTIFICATION_ID,
            "vcsRootId": self.root,
            "branch": self.branch,
            "coverageSHA256": hashlib.sha256(contents).hexdigest(),
            "html_url": f"{self.base}/build/{build_id}",
            "head_sha": revision,
        }

    def promoted(self, repository, configuration_id):
        """Read the build selected by TeamCity for this chain and its immutable revision."""
        current = self.require_current_checkout(repository, configuration_id)
        dependencies = (current.get("snapshot-dependencies") or {}).get("build", [])
        selected = [item for item in dependencies if item.get("buildTypeId") == CERTIFICATION_ID]
        if len(selected) != 1:
            raise ValueError("Release requires exactly one Offline certification snapshot dependency")
        build = self.build(selected[0].get("id"))
        revision = self.default_revision(build)
        if revision is None or (evidence := self.evidence(build, revision)) is None:
            raise ValueError("Promote a successful default-branch TeamCity Offline certification build")
        return evidence
