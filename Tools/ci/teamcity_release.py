# File: Tools/ci/teamcity_release.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Validate the same-chain TeamCity certification used for a DiscordKit release."""

import hashlib
import json
import os
import re
import subprocess
from urllib.request import HTTPRedirectHandler


TEAMCITY_URL = "https://ci.aurum-studios.com"
CERTIFICATION_ID = "DiscordKit_Certification"
CERTIFICATION_RECEIPT = ".build/teamcity/in/certification/certification.json"
BUILD_NUMBER_PATTERN = r"[1-9][0-9]*"


class RejectRedirects(HTTPRedirectHandler):
    """Avoid forwarding a credential to a redirect target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        """Reject redirected requests so the original credential stays on its origin."""
        return None


class TeamCityCertification:
    """Bind a release job to its exact TeamCity snapshot dependency and coverage receipt."""

    def __init__(self):
        """Read the trusted VCS root and default branch configured for release builds."""
        self.root = os.environ["TEAMCITY_VCS_ROOT_ID"]
        self.branch = os.environ["RELEASE_DEFAULT_BRANCH"]
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", self.root):
            raise ValueError("Invalid TeamCity VCS root ID")

    def require_current_checkout(self, repository, configuration_id):
        """Require the intended release job and its default-branch tooling checkout."""
        if os.environ.get("TEAMCITY_DEFAULT_BRANCH") != "true":
            raise ValueError("Run the release from the repository's default branch")
        head = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
        if (os.environ.get("TEAMCITY_BUILD_TYPE_ID") != configuration_id
                or os.environ.get("DISCORDKIT_VCS_REVISION") != head):
            raise ValueError("Release tooling must use the current TeamCity default-branch checkout")

    def promoted(self, repository, configuration_id):
        """Validate the promoted build's chain properties and sealed receipt in this job."""
        self.require_current_checkout(repository, configuration_id)
        build_id = os.environ.get("TEAMCITY_CERTIFICATION_BUILD_ID", "")
        number = os.environ.get("TEAMCITY_CERTIFICATION_BUILD_NUMBER", "")
        revision = os.environ.get("TEAMCITY_CERTIFICATION_REVISION", "")
        if os.environ.get("TEAMCITY_CERTIFICATION_DEFAULT_BRANCH") != "true":
            raise ValueError("Promote a successful default-branch TeamCity Offline certification build")
        if not re.fullmatch(BUILD_NUMBER_PATTERN, build_id):
            raise ValueError("Invalid TeamCity certification build ID")
        if not re.fullmatch(BUILD_NUMBER_PATTERN, number):
            raise ValueError("Invalid TeamCity certification build number")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Invalid TeamCity certification revision")

        contents = (repository / CERTIFICATION_RECEIPT).read_bytes()
        receipt = json.loads(contents)
        prerequisites = receipt.get("prerequisites")
        doc_digest = receipt.get("documentationArchiveSHA256")
        if (receipt.get("schemaVersion") != 1 or receipt.get("status") != "passed"
                or receipt.get("buildId") != build_id or receipt.get("revision") != revision
                or not isinstance(doc_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", doc_digest)
                or not isinstance(prerequisites, dict) or not prerequisites
                or any(not isinstance(item, str) or not re.fullmatch(BUILD_NUMBER_PATTERN, item)
                       or item == build_id for item in prerequisites.values())
                or len(set(prerequisites.values())) != len(prerequisites)):
            raise ValueError("TeamCity certification did not produce complete coverage evidence")
        return {
            "provider": "teamcity",
            "id": int(build_id),
            "number": number,
            "buildTypeId": CERTIFICATION_ID,
            "vcsRootId": self.root,
            "branch": self.branch,
            "coverageSHA256": hashlib.sha256(contents).hexdigest(),
            "html_url": f"{TEAMCITY_URL}/build/{build_id}",
            "head_sha": revision,
        }
