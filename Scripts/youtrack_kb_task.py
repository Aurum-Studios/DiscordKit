#!/usr/bin/env python3
# copyright:begin
# File: Scripts/youtrack_kb_task.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Prepare committed Air task content and checkpoint verified YouTrack effects."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
import youtrack_knowledge_base as kb


HISTORY_KEY = "group:project-history"
FULL_SHA = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
ISSUE_ID = re.compile(r"[A-Z][A-Z0-9_-]{0,63}-[1-9][0-9]*")
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
MARKER_PREFIX = "<!-- air-task-kb:"
STAGE = re.compile(r"[A-Za-z][A-Za-z0-9 -]{0,47}")
DELIVERY_STAGES = {"deployment": 1, "verification": 2, "done": 3}


def issue_directory(home, issue):
    """Return one safe private directory shared by worktrees for a literal issue."""
    if not isinstance(issue, str) or not ISSUE_ID.fullmatch(issue):
        raise ValueError("Task publication requires a canonical YouTrack issue ID")
    return kb.safe_path(home / "tasks" / issue, home)


def commit(root, value):
    """Require a complete Git commit ID without symbolic references or tag dereferencing."""
    if not isinstance(value, str) or not FULL_SHA.fullmatch(value):
        raise ValueError("Task publication requires full lowercase Git commit IDs")
    if kb.git(root, "cat-file", "-t", value).strip() != "commit":
        raise ValueError("Task publication source must be a Git commit")
    return value


def ancestor(root, earlier, later):
    """Reject stale or divergent task checkpoints before publishing."""
    if kb.git(root, "merge-base", "--is-ancestor", earlier, later, optional=True) is None:
        raise ValueError("Task checkpoint must descend from its approval and last publication")


def committed_text(root, revision, path, limit):
    """Read exact UTF-8 bytes of a size-bounded committed regular file."""
    entry = kb.git(root, "ls-tree", "-z", revision, "--", path, binary=True)
    expected = re.fullmatch(rb"100(?:644|755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t"
                            + re.escape(path.encode("utf-8")) + rb"\x00", entry)
    if expected is None:
        raise ValueError("Missing committed regular task file: " + path)
    blob = expected.group(1).decode("ascii")
    if int(kb.git(root, "cat-file", "-s", blob).strip()) > limit:
        raise ValueError("Committed task file exceeds the publication size limit: " + path)
    return kb.git(root, "cat-file", "blob", blob, binary=True).decode("utf-8")


def history(home, scope):
    """Read the verified Project History ID, canonical URL and retained scope."""
    path = kb.safe_path(home / "baseline.json", home)
    if not path.exists():
        raise ValueError("Task publication is pending a verified Project History receipt")
    baseline = kb.read(path)
    if kb.ownership(baseline["binding"]) != kb.ownership(scope):
        raise ValueError("Project History receipt belongs to another project or audience")
    record = baseline["articles"].get(HISTORY_KEY)
    if not record or record.get("retired") or record.get("parent") is not None:
        raise ValueError("Task publication is pending an active top-level Project History receipt")
    identifier = kb.article_identifier(record["id"])
    if not identifier.startswith(scope["project"] + "-A-"):
        raise ValueError("Project History article belongs to a different project")
    url = kb.verified_url(baseline["urls"].get(HISTORY_KEY), identifier)
    return {"id": identifier, "url": url, "summary": record["summary"]}


def prepare(root, home, issue, task):
    """Validate the approved Git source and return only publication-safe task material."""
    scope = kb.settings(root)
    if scope.get("layout") != "project":
        raise ValueError("Task publication requires the project Knowledge Base layout")
    if task.get("issueId") != issue or issue.rsplit("-", 1)[0] != scope["project"]:
        raise ValueError("Task issue does not belong to the configured YouTrack project")
    approved = commit(root, task.get("approvedPlanCommit"))
    candidate = commit(root, task.get("candidateCommit"))
    if kb.git(root, "rev-parse", "HEAD").strip() != candidate:
        raise ValueError("Task publication requires the current committed checkpoint")
    ancestor(root, approved, candidate)
    run = task.get("runId")
    stage = task.get("stage")
    progress = task.get("progress")
    if not isinstance(run, str) or not RUN_ID.fullmatch(run):
        raise ValueError("Task publication requires a literal Air run ID")
    if not isinstance(stage, str) or not STAGE.fullmatch(stage):
        raise ValueError("Task publication requires a plain-text Air stage")
    if (not isinstance(progress, str) or not progress.strip() or len(progress.encode("utf-8")) > 2048
            or any(ord(character) < 32 and character not in "\t\n" for character in progress)
            or MARKER_PREFIX in progress):
        raise ValueError("Task publication requires bounded reviewed Markdown progress")
    directory = f"Docs/Tasks/{issue}/{run}"
    state = committed_text(root, candidate, directory + "/STATE.md", 65536)
    approvals = [line for line in state.splitlines() if line.startswith("Knowledge Base plan approval:")]
    if approvals != ["Knowledge Base plan approval: " + approved]:
        raise ValueError("Task publication is pending the exact committed plan approval")
    plan = committed_text(root, approved, directory + "/PLAN.md", 27000).replace("\r\n", "\n")
    if not plan.strip() or "\x00" in plan or MARKER_PREFIX in plan:
        raise ValueError("Approved plan is empty or contains reserved publication syntax")
    destination = history(home, scope)
    marker = kb.sha(scope["namespace_uuid"] + "\n" + scope["project"] + "\n" + issue)
    return {"scope": scope, "history": destination, "plan": plan, "marker": marker,
            "candidate": candidate, "approved": approved, "run": run, "stage": stage, "progress": progress,
            "identity": {"issue": issue, "history": destination["id"], "marker": marker}}


def receipt(path):
    """Return this issue's durable receipt or a new empty workflow state."""
    return kb.read(path) if path.exists() else {}


def record(root, path, payload):
    """Persist task intent before sending it or commit a positively verified readback."""
    current = receipt(path)
    if current and current.get("identity") != payload.get("identity"):
        raise ValueError("Task receipt identity changed during publication")
    operation = payload["operation"]
    actual = payload.get("actual")
    if operation == "article-intent":
        target = payload["target"]
        if len(target["content"].encode("utf-8")) > 30000:
            raise ValueError("Task article would exceed the connector's UTF-8 publication limit")
        if current.get("article_intent") or current.get("active_backlink"):
            raise ValueError("Reconcile the pending task write before creating another intent")
        if current.get("candidate") and current["candidate"] != target["candidate"]:
            ancestor(root, current["candidate"], target["candidate"])
        if (current.get("run") == target.get("run")
                and DELIVERY_STAGES.get(current.get("stage", "").lower(), 0)
                > DELIVERY_STAGES.get(target.get("stage", "").lower(), 0)):
            raise ValueError("An Air run cannot move backward from its recorded delivery stage")
        current["identity"] = payload["identity"]
        current["article_intent"] = target
    elif operation == "article-verified":
        target = current["article_intent"]
        if not isinstance(actual, dict) or actual.get("content") != target["content"]:
            raise ValueError("Task article readback differs from the durable intent")
        identifier = kb.article_identifier(actual["id"])
        if current.get("article_id", identifier) != identifier:
            raise ValueError("Task publication cannot replace its verified article ID")
        current.update(article_id=identifier, article_url=kb.verified_url(actual["url"], identifier),
                       owned=target["owned"], candidate=target["candidate"], approved=target["approved"],
                       run=target.get("run"), stage=target.get("stage", ""))
        del current["article_intent"]
    elif operation == "backlink-intent":
        if current.get("active_backlink") or current.get("backlink_id") or not current.get("article_id"):
            raise ValueError("Task already has a pending or verified issue backlink")
        current["active_backlink"] = True
    elif operation == "backlink-verified":
        if not isinstance(actual, str) or not actual or current.get("backlink_id", actual) != actual:
            raise ValueError("Task backlink identity differs from the verified receipt")
        current["backlink_id"] = actual
        current.pop("active_backlink", None)
    else:
        raise ValueError("Unknown task publication receipt operation")
    kb.save(path, current)
    return current


def main(argv=None):
    """Dispatch local source, journal and private connector-payload operations."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "record", "payload-init", "payload-append"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--issue", required=True)
    parser.add_argument("--payload")
    parser.add_argument("--payload-file", type=Path)
    parser.add_argument("--chunk", default="")
    args = parser.parse_args(argv)
    try:
        root = kb.repository(args.root)
        home = kb.repository_state_dir(root)
        directory = issue_directory(home, args.issue)
        path = kb.safe_path(directory / "receipt.json", home)
        if args.command == "payload-init":
            result = kb.payload_init(directory)
        elif args.command == "payload-append":
            result = kb.payload_append(directory, args.payload_file, args.chunk)
        else:
            if args.payload_file is None:
                payload = json.loads(args.payload)
            else:
                scratch = kb.payload_path(directory, args.payload_file)
                try:
                    payload = kb.read(scratch)
                finally:
                    scratch.unlink()
            if args.command == "prepare":
                result = prepare(root, home, args.issue, payload)
                current = receipt(path)
                if current and current.get("identity") != result["identity"]:
                    raise ValueError("Task receipt does not match the configured project and issue")
                if current.get("candidate"):
                    ancestor(root, current["candidate"], result["candidate"])
                result["receipt"] = current
            else:
                result = record(root, path, payload)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, UnicodeError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print("YouTrack task publication: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
