#!/usr/bin/env python3
# copyright:begin
# File: Scripts/youtrack_knowledge_base.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Checkpoint portable Markdown publication through authenticated MCP callers.

This standard-library helper reads repository sources and writes only private
sync snapshots and receipts in the Git common directory. Network operations are
owned by the companion JavaScript runner; source content is always data.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
import youtrack_kb_renderer as renderer


EXCLUDED = {".git", ".build", ".venv", "venv", "node_modules", "vendor", "build", "dist", "target",
            "coverage", ".next", ".nuxt", ".cache", "__pycache__", "_site", ".jekyll-cache",
            "docc-output", "Library", "Temp", "Logs", "obj", "bin"}
PAYLOAD_BYTES = 4 * 1024 * 1024
PROJECT_CONFIG = ".air/project.json"
GUIDE_MANIFEST = ".air/youtrack/project-guides.json"


def sha(value):
    """Hash exact bytes or UTF-8 text for source, intent and article receipts."""
    return hashlib.sha256(value.encode("utf-8") if isinstance(value, str) else value).hexdigest()


def safe_path(path, boundary=None):
    """Reject symbolic links and non-directory ancestors beneath a trusted boundary."""
    path = Path(path)
    stop = Path(boundary) if boundary is not None else Path(path.anchor)
    if boundary is not None and path != stop and stop not in path.parents:
        raise ValueError("Sync path is outside its owned state directory")
    for current in (path,) + tuple(path.parents):
        if current.is_symlink():
            raise ValueError("Symbolic links are not permitted in sync state")
        if current != path and current.exists() and not current.is_dir():
            raise ValueError("Sync state has a blocked parent directory")
        if current == stop:
            break
    return path


def read(path):
    """Read a regular JSON receipt without following a symbolic link."""
    path = safe_path(Path(path))
    if not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError("Required sync receipt is missing")
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, value):
    """Atomically replace private JSON state after validating its real ancestors."""
    path = safe_path(Path(path))
    ensure_directory(path.parent)
    safe_path(path)
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".kb-", dir=str(path.parent))
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        safe_path(path)
        os.replace(temporary, path)
        temporary = None
        sync_directory(path.parent)
    finally:
        if temporary is not None:
            Path(temporary).unlink()


def sync_directory(path):
    """Persist directory-entry changes before allowing a related remote mutation."""
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_directory(path):
    """Create private state ancestors and persist every new directory entry."""
    path = safe_path(Path(path))
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    if not current.is_dir():
        raise ValueError("Sync state directory is blocked by another file")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        sync_directory(directory.parent)


def git(root, *arguments, binary=False, optional=False):
    """Execute a bounded read-only Git query with literal arguments."""
    result = subprocess.run(["git", "-C", str(root), *arguments], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=not binary, timeout=30)
    if result.returncode:
        if optional:
            return None
        raise ValueError("Required read-only Git query failed")
    return result.stdout


def repository(root):
    """Require the selected source folder to be its exact non-bare Git root."""
    root = Path(root).resolve()
    result = git(root, "rev-parse", "--is-bare-repository", "--show-toplevel")
    bare, separator, top = result.partition("\n")
    if bare != "false" or not separator:
        raise ValueError("Knowledge Base synchronization needs a non-bare repository")
    if Path(top[:-1] if top.endswith("\n") else top).resolve() != root:
        raise ValueError("Source must be the repository root")
    return root


def state_dir(root):
    """Resolve one coordinator and receipt directory shared by linked worktrees."""
    root = repository(root)
    return repository_state_dir(root)


def repository_state_dir(root):
    """Resolve receipt storage after the caller has validated the exact Git root."""
    common = Path(git(root, "rev-parse", "--git-common-dir").strip())
    if not common.is_absolute():
        common = root / common
    common = common.resolve()
    home = common / "air-workflow" / "youtrack-kb-v1"
    safe_path(home, common)
    return home


def overview_text(value, limit):
    """Keep plain project metadata on one line with a bounded snapshot length."""
    if not isinstance(value, str):
        return ""
    text = " ".join(value.split())
    text = "".join(character for character in text if character.isprintable())
    if len(text) > limit:
        return text[:limit - 1].rstrip() + "…"
    return text


def project_guides(root):
    """Load the ordered allowlist of Markdown pages approved for the project library."""
    manifest = read(safe_path(root / GUIDE_MANIFEST, root))
    if not isinstance(manifest, dict) or manifest.get("version") != 1:
        raise ValueError("The Knowledge Base requires a version 1 guide manifest")
    entries = manifest.get("sources")
    if not isinstance(entries, list) or not entries:
        raise ValueError("The Knowledge Base requires a nonempty source allowlist")
    sections = {key[6:] for key, _, _ in renderer.PROJECT_SECTIONS if key != "group:root"}
    guides, titles = {}, set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "section", "title"}:
            raise ValueError("Each guide requires a path, section and title")
        relative, section, title = entry["path"], entry["section"], entry["title"]
        if not isinstance(relative, str) or not re.fullmatch(
                r"(?:README|CONTRIBUTING|CHANGELOG)\.md|Docs/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.md", relative):
            raise ValueError("Each guide path must name a supported Markdown source")
        if relative in guides or not isinstance(section, str) or section not in sections:
            raise ValueError("A guide path is duplicated or its section is unsupported: " + relative)
        if not isinstance(title, str) or not title.strip() or len(title) > 160 or not title.isprintable():
            raise ValueError("Each guide title must be nonempty printable text: " + relative)
        title_key = section, title.casefold()
        if title_key in titles:
            raise ValueError("A guide title is duplicated in its section: " + title)
        titles.add(title_key)
        guides[relative] = ["group:" + section, title]
    return guides


def settings(root, *, local_verify=False):
    """Validate project identity, library layout, audience and explicit repository URL."""
    path = safe_path(Path(root) / PROJECT_CONFIG, Path(root))
    config = read(path)
    if not isinstance(config, dict):
        raise ValueError("Repository configuration must be a JSON object")
    tracker = config.get("tracker", {})
    knowledge = config.get("knowledge_base", {})
    identity = config.get("identity", {})
    if not all(isinstance(value, dict) for value in (tracker, knowledge, identity)):
        raise ValueError("Repository tracker, identity and Knowledge Base settings must be objects")
    if tracker.get("mode") != "youtrack" or knowledge.get("enabled") is not True:
        raise ValueError("Knowledge Base sync is disabled for this repository")
    project = tracker.get("project_key")
    if not (local_verify and project is None) and (
            not isinstance(project, str) or not re.fullmatch(r"[A-Z][A-Z0-9_-]{0,63}", project)):
        raise ValueError("Knowledge Base sync is pending a verified YouTrack project key")
    namespace = identity.get("uuid")
    try:
        namespace = str(uuid.UUID(namespace))
    except (ValueError, TypeError, AttributeError):
        raise ValueError("Knowledge Base sync requires a recorded repository namespace UUID") from None
    layout = knowledge.get("layout", "repository")
    if layout not in ("project", "repository"):
        raise ValueError("Knowledge Base layout must be project or repository")
    title = "Overview" if layout == "project" else knowledge.get("root_title")
    if not isinstance(title, str) or not title.strip() or len(title) > 240 or any(ord(character) < 32 for character in title):
        raise ValueError("Knowledge Base root_title must be plain text of at most 240 characters")
    audience = {}
    for key in ("permitted_groups", "permitted_users"):
        values = knowledge.get(key)
        if not isinstance(values, list) or any(not isinstance(item, str) or not item.strip() or any(ord(character) < 32 for character in item) for item in values):
            raise ValueError("Knowledge Base audience must contain explicit group names or user logins")
        if len(set(values)) != len(values):
            raise ValueError("Knowledge Base audience contains duplicate identities")
        audience[key] = sorted(values)
    allowed_groups = ([], ["DiscordKit Team"]) if local_verify else (["DiscordKit Team"],)
    if audience["permitted_groups"] not in allowed_groups or audience["permitted_users"]:
        raise ValueError("The DiscordKit Knowledge Base requires the verified DiscordKit Team audience")
    source = knowledge.get("source_url")
    if source is not None:
        if not isinstance(source, str):
            raise ValueError("source_url must be an explicit HTTPS repository web root or null")
        parsed = urlsplit(source)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or any(character.isspace() or ord(character) < 32 for character in source):
            raise ValueError("source_url must be an HTTPS repository web root without credentials, query or fragment")
        source = source.rstrip("/")
    binding = {"project": project, "namespace_uuid": namespace, "root_title": title,
               "source_url": source, **audience}
    if layout == "project":
        metadata = config.get("project", {})
        if not isinstance(metadata, dict):
            raise ValueError("Project metadata for the Knowledge Base Overview must be an object")
        binding["layout"] = layout
        binding["overview"] = {"name": overview_text(metadata.get("name"), 120),
                               "description": overview_text(metadata.get("description"), 1000)}
        binding["project_guides"] = project_guides(Path(root))
    return binding


def ownership(binding):
    """Extract destination ownership separately from changeable presentation settings."""
    scope = {key: binding[key] for key in ("project", "namespace_uuid", "permitted_groups", "permitted_users")}
    if binding.get("layout") == "project":
        scope["layout"] = "project"
    return scope


def has_effects(state, baseline):
    """Distinguish untouched local preparation from durable remote-operation intent."""
    mapping = {key: value["id"] for key, value in baseline["articles"].items()}
    return bool(state.get("intents") or state.get("outcomes") or state["mapping"] != mapping)


def owned_run(root, home, run, exact_settings=True):
    """Verify run ownership, pinning full settings while durable work is pending.

    Preparation may inspect an untouched preview without pinning its presentation
    settings; all mutating commands keep the default exact-settings check.
    """
    home = Path(home)
    path = Path(run)
    if not path.is_absolute():
        raise ValueError("Sync run must be an absolute owned snapshot directory")
    if path.parent != home / "runs" or not re.fullmatch(r"[0-9a-f]{32}", path.name):
        raise ValueError("Sync run is outside this repository's receipt directory")
    safe_path(path, home)
    state = read(path / "state.json")
    if exact_settings and state["binding"] != settings(root):
        raise ValueError("Repository settings differ from the pending sync receipt")
    if Path(state["root"]).resolve() != Path(root).resolve():
        raise ValueError("Pending sync belongs to another worktree; resume it from its recorded source")
    return path


def included(root, path):
    """Allow only real regular source files inside the selected checkout."""
    if not path.is_file() or path.is_symlink():
        return False
    if root not in path.parents:
        return False
    return not any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents)


def snapshot(root, run, base, binding, *, durable=True):
    """Capture eligible sources for the approved layout without reading outputs or symlinks."""
    root, run = Path(root), Path(run)
    head = git(root, "rev-parse", "--verify", "HEAD", optional=True)
    head = head.strip() if head else None
    tracked = git(root, "ls-files", "-z").split("\0")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
    candidates = sorted({value for value in tracked + untracked if value and not set(Path(value).parts).intersection(EXCLUDED)})
    versioned = git(root, "ls-tree", "-rz", "--name-only", head, optional=True).split("\0") if head else []
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    sources = run / "sources"
    safe_path(sources)
    if durable:
        ensure_directory(sources)
    else:
        sources.mkdir()
    files, inputs = [], {}
    project_layout = binding.get("layout") == "project"
    sources_to_read = binding["project_guides"] if project_layout else candidates
    missing = set(sources_to_read) - set(candidates)
    if missing:
        raise ValueError("Required guides are absent or ignored: " + ", ".join(sorted(missing)))
    for relative in sources_to_read:
        path = root / relative
        if path.suffix.lower() not in (".md", ".markdown") or not included(root, path):
            if project_layout:
                raise ValueError("Required guide must be a regular source file: " + relative)
            continue
        raw = path.read_bytes()
        text = raw.decode("utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")
        old = base.get("files", {}).get(relative, {})
        raw_hash, text_hash = sha(raw), sha(text)
        committed = git(root, "show", head + ":" + relative, binary=True, optional=True) if head and relative in versioned else None
        dirty = committed is None or committed != raw
        same = old.get("sha256") == raw_hash and old.get("text_sha256") == text_hash
        filename = str(len(files)).zfill(5) + ".md"
        (sources / filename).write_text(text, encoding="utf-8")
        files.append({"path": relative, "snapshot_file": filename, "sha256": raw_hash,
                      "text_sha256": text_hash, "dirty": dirty, "versioned": committed is not None,
                      "head": head, "snapshot": old.get("snapshot", stamp) if same else stamp})
        inputs[relative] = raw_hash
    paths = (PROJECT_CONFIG, GUIDE_MANIFEST) if project_layout else (PROJECT_CONFIG,)
    configuration = {}
    for relative in paths:
        raw = safe_path(root / relative, root).read_bytes()
        committed = git(root, "show", head + ":" + relative, binary=True, optional=True) if head else None
        configuration[relative] = {"sha256": sha(raw), "dirty": raw != committed}
    return {"root": str(root), "head": head, "snapshot": stamp, "tracked": candidates,
            "versioned_paths": [value for value in versioned if value], "files": files, "inputs": inputs,
            "configuration": configuration}


def prepare(root, home):
    """Resume durable work or create a fully rendered, identity-bound source snapshot."""
    root = repository(root)
    home = Path(home)
    if home != repository_state_dir(root):
        raise ValueError("Sync receipt directory does not belong to this repository")
    safe_path(home)
    ensure_directory(home)
    binding = settings(root)
    baseline_path = home / "baseline.json"
    baseline = read(baseline_path) if baseline_path.exists() else {"version": 1, "binding": binding, "files": {}, "articles": {}, "urls": {}}
    active = home / "active.json"
    pending_state = None
    pending_baseline = None
    if active.exists():
        run = owned_run(root, home, read(active)["run"], exact_settings=False)
        pending_state = read(run / "state.json")
        pending_baseline = read(run / "baseline.json")
    effects = pending_state is not None and has_effects(pending_state, pending_baseline)
    scope = home / "scope.json"
    if scope.exists():
        saved_scope = read(scope)
        locked = saved_scope.get("ownership_locked", bool(baseline["articles"]) or effects)
        if ownership(saved_scope) != ownership(binding):
            if locked or baseline["articles"] or effects:
                raise ValueError("Saved Knowledge Base scope differs from this repository's project, identity, audience or layout")
            save(scope, {**ownership(binding), "ownership_locked": False})
    else:
        durable_binding = baseline["binding"] if baseline["articles"] else pending_state["binding"] if effects else binding
        if ownership(durable_binding) != ownership(binding):
            raise ValueError("Existing Knowledge Base receipts belong to a different ownership scope")
        save(scope, {**ownership(binding), "ownership_locked": bool(baseline["articles"]) or effects})
    if pending_state is not None:
        if effects:
            if pending_state["binding"] != binding:
                raise ValueError("Repository settings differ from the pending sync receipt")
            return prepared_report(run, pending_state, True)
        active.unlink()
        sync_directory(home)
    if baseline["articles"] and ownership(baseline["binding"]) != ownership(binding):
        raise ValueError("Verified baseline belongs to a different Knowledge Base scope")
    run = home / "runs" / uuid.uuid4().hex
    safe_path(run, home)
    ensure_directory(run)
    save(run / "baseline.json", baseline)
    inventory = snapshot(root, run, baseline, binding)
    inventory["binding"] = binding
    articles, chunks = renderer.build(inventory, run)
    keys = {article["key"] for article in articles}
    for key, previous in baseline["articles"].items():
        if key not in keys:
            articles.append({"key": key, "summary": previous["summary"], "parent": previous["parent"], "kind": "retired", "retired": True})
    state = {**inventory, "version": 1, "articles": articles, "chunks": chunks,
             "mapping": {key: value["id"] for key, value in baseline["articles"].items()},
             "urls": dict(baseline.get("urls", {})), "outcomes": {}, "intents": {}}
    state["baseline_sha256"] = sha(baseline_path.read_bytes()) if baseline_path.exists() else None
    old_files = baseline["files"]
    state["changed_sources"] = sorted(source["path"] for source in state["files"] if old_files.get(source["path"], {}).get("sha256") != source["sha256"])
    state["removed_sources"] = sorted(set(old_files) - set(state["inputs"]))
    save(run / "state.json", state)
    render(run)
    save(active, {"run": str(run)})
    return prepared_report(run, read(run / "state.json"), False)


def prepared_report(run, state, resumed):
    """Expose destination and inventory metadata without dumping source bodies."""
    return {"run": str(run), "resumed": resumed, "source_documents": len(state["files"]),
            "revision": state["head"], "working_copy_sources": sum(source["dirty"] for source in state["files"]),
            "working_copy_configuration": sum(entry["dirty"] for entry in state["configuration"].values()),
            "link_warnings": len(state.get("link_warnings", [])),
            "changed_sources": len(state["changed_sources"]), "removed_sources": state["removed_sources"],
            "new_articles": sum(article["key"] not in state["mapping"] for article in state["articles"]),
            "project": state["binding"]["project"], "root_title": state["binding"]["root_title"],
            "permitted_groups": state["binding"]["permitted_groups"], "permitted_users": state["binding"]["permitted_users"],
            "root_id": state["mapping"].get("group:root"), "root_url": state["urls"].get("group:root")}


def verify(root, binding, revision=None):
    """Render a disposable, offline preview and check an exact candidate when supplied."""
    with tempfile.TemporaryDirectory(prefix="discordkit-kb-verify-") as temporary:
        run = Path(temporary).resolve()
        state = snapshot(root, run, {}, binding, durable=False)
        state["binding"] = binding
        articles, chunks = renderer.build(state, run)
        state.update(articles=articles, chunks=chunks, mapping={}, urls={})
        renderer.render(state, run)
        dirty_sources = [source["path"] for source in state["files"] if source["dirty"]]
        dirty_configuration = [path for path, entry in state["configuration"].items() if entry["dirty"]]
        if revision is not None and (state["head"] != revision or dirty_sources or dirty_configuration):
            raise ValueError("Knowledge Base inputs must match the specified committed revision")
        warnings = state.get("link_warnings", [])
        if revision is not None and warnings:
            raise ValueError("Knowledge Base link warnings: " + json.dumps(warnings, ensure_ascii=False))
        return {"verified": True, "revision": state["head"], "source_documents": len(state["files"]),
                "planned_pages": len(articles), "working_copy_sources": len(dirty_sources),
                "working_copy_configuration": len(dirty_configuration), "link_warnings": warnings,
                "source_sha256": sha(json.dumps(state["inputs"], sort_keys=True)),
                "guide_manifest_sha256": state["configuration"].get(GUIDE_MANIFEST, {}).get("sha256")}


def render(run):
    """Render intended pages while keeping retired narrative and IDs recoverable."""
    run = Path(run)
    state = read(run / "state.json")
    baseline = read(run / "baseline.json")
    state = renderer.render(state, run)
    for number, article in enumerate(state["articles"]):
        if not article.get("retired"):
            continue
        previous = baseline["articles"][article["key"]]
        article["content_sha256"] = previous["content_sha256"] if previous.get("retired") else None
        article["rendered"] = "retired-" + str(number).zfill(5) + ".md"
        if previous.get("retired"):
            article["reuse"] = True
        else:
            article["reuse"] = False
            path = run / "rendered" / article["rendered"]
            if path.exists():
                article["content_sha256"] = sha(path.read_text(encoding="utf-8"))
    save(run / "state.json", state)
    return {"articles": len(state["articles"]), "link_warnings": state.get("link_warnings", []), "link_stats": state.get("link_stats", {})}


def catalog(run, offset=0, limit=50):
    """Return bounded article identities and pending creation intents for the runner."""
    if offset < 0 or limit < 1 or limit > 100:
        raise ValueError("Catalog pagination must use a nonnegative offset and limit 1–100")
    state = read(Path(run) / "state.json")
    items = []
    for article in state["articles"][offset:offset + limit]:
        items.append({**{key: article.get(key) for key in ("key", "summary", "parent", "kind", "retired")},
                      "id": state["mapping"].get(article["key"]), "intent": state["intents"].get(article["key"])})
    return {"total": len(state["articles"]), "articles": items}


def plan(run, key=None):
    """Expose one full intended article and its previously verified baseline."""
    state = read(Path(run) / "state.json")
    if key is None:
        return {"articles": state["articles"], "mapping": state["mapping"], "intents": state["intents"], "outcomes": state["outcomes"]}
    article = next((value for value in state["articles"] if value["key"] == key), None)
    if article is None:
        raise ValueError("Unknown article key")
    baseline = read(Path(run) / "baseline.json")
    result = {**article, "id": state["mapping"].get(key), "parent_id": state["mapping"].get(article["parent"]),
              "expected": baseline["articles"].get(key), "intent": state["intents"].get(key)}
    path = Path(run) / "rendered" / article.get("rendered", "")
    if path.is_file():
        result["content"] = path.read_text(encoding="utf-8")
    return result


def article_identifier(value):
    """Require a literal YouTrack article identity before persisting it."""
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*-A-[0-9]+", value):
        raise ValueError("Invalid YouTrack article ID")
    return value


def verified_url(value, identifier):
    """Accept only credential-free HTTPS article URLs returned by the connector."""
    if not isinstance(value, str):
        raise ValueError("The connector did not provide the actual documentation root URL")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or any(character.isspace() or ord(character) < 32 for character in value):
        raise ValueError("Connector article URL is not a safe HTTPS URL")
    if not parsed.path.endswith("/articles/" + identifier):
        raise ValueError("Connector article URL differs from the recorded article ID")
    return value


def record(run, payload):
    """Persist pre-write intent, reconciled identities and verified article outcomes."""
    run = Path(run)
    state = read(run / "state.json")
    key = payload.get("key")
    article = next((value for value in state["articles"] if value["key"] == key), None)
    if article is None:
        raise ValueError("Cannot record an unknown article key")
    operation = payload.get("operation")
    if operation == "intent":
        placeholder = payload.get("placeholder")
        marker = payload.get("marker")
        if key in state["mapping"] or key in state["intents"] or not isinstance(placeholder, str) or not isinstance(marker, str) or marker not in placeholder:
            raise ValueError("Creation intent is invalid or already durable")
        scope_path = run.parent.parent / "scope.json"
        saved_scope = read(scope_path)
        if ownership(saved_scope) != ownership(state["binding"]):
            raise ValueError("Creation intent differs from the saved Knowledge Base ownership")
        if saved_scope.get("ownership_locked") is not True:
            save(scope_path, {**ownership(state["binding"]), "ownership_locked": True})
        state["intents"][key] = {**payload, "placeholder_sha256": sha(placeholder)}
    elif operation == "created":
        identifier = article_identifier(payload.get("id"))
        if key not in state["intents"] or (key in state["mapping"] and state["mapping"][key] != identifier):
            raise ValueError("Created identity lacks its original durable intent")
        if not identifier.startswith(state["binding"]["project"] + "-A-"):
            raise ValueError("Created article belongs to another project")
        url = payload.get("url")
        if key == "group:root" or url is not None:
            actual_url = verified_url(url, identifier)
            root_url = state["urls"].get("group:root")
            if key != "group:root" and (not root_url or actual_url != root_url.rsplit("/", 1)[0] + "/" + identifier):
                raise ValueError("Created article URL differs from the verified YouTrack server")
            state["urls"][key] = actual_url
        state["mapping"][key] = identifier
    elif operation in ("result", "update_intent"):
        if key not in state["mapping"]:
            raise ValueError("Cannot record a result before article identity is known")
        if operation == "result" and payload.get("status") not in ("verified", "unchanged", "conflict"):
            raise ValueError("Article result has an unknown verification status")
        if payload.get("id") is not None and payload["id"] != state["mapping"][key]:
            raise ValueError("Article result identity differs from its receipt")
        state["outcomes"][key] = payload
    else:
        raise ValueError("Unknown sync receipt operation")
    save(run / "state.json", state)
    receipt = safe_path(run / "receipts.jsonl")
    if receipt.exists() and (not receipt.is_file() or receipt.stat().st_nlink != 1):
        raise ValueError("Sync receipt is not an exclusively owned regular file")
    descriptor = os.open(str(receipt), os.O_CREAT | os.O_APPEND | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, ensure_ascii=False) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    sync_directory(run)
    return {"recorded": key}


def names(values, user=False):
    """Normalize connector audience strings or identity objects without losing scope."""
    if not isinstance(values, list):
        return None
    normalized = []
    for value in values:
        name = value if isinstance(value, str) else value.get("login" if user else "name") if isinstance(value, dict) else None
        if not isinstance(name, str):
            return None
        normalized.append(name)
    return sorted(normalized)


def assess(run, payload):
    """Refuse remote drift and return an exact hash-qualified replacement if owned."""
    run = Path(run)
    state = read(run / "state.json")
    key, remote = payload.get("key"), payload.get("remote")
    article = next((value for value in state["articles"] if value["key"] == key), None)
    if article is None or not isinstance(remote, dict) or not isinstance(remote.get("content"), str):
        raise ValueError("Article assessment requires a known key and full connector content")
    project = remote.get("project")
    if isinstance(project, dict):
        project = project.get("shortName") or project.get("key")
    parent = (remote.get("parentArticle") or {}).get("id")
    metadata = (project == state["binding"]["project"] and remote.get("id") == state["mapping"].get(key)
                and remote.get("url") == renderer.article_url(state, key)
                and parent == state["mapping"].get(article["parent"])
                and names(remote.get("permittedGroups")) == state["binding"]["permitted_groups"]
                and names(remote.get("permittedUsers"), True) == state["binding"]["permitted_users"])
    actual = sha(remote["content"])
    baseline = read(run / "baseline.json")["articles"].get(key)
    expected = baseline["content_sha256"] if baseline else state["intents"].get(key, {}).get("placeholder_sha256")
    expected_summary = baseline["summary"] if baseline else article["summary"]
    if metadata and remote.get("summary") == article["summary"] and actual == article["content_sha256"]:
        return {"action": "unchanged", "hash": actual}
    if not metadata or remote.get("summary") != expected_summary or actual != expected:
        return {"action": "conflict", "reason": "Remote content, title, parent, project or visibility differs from the verified receipt"}
    if article.get("retired"):
        if baseline.get("retired"):
            return {"action": "conflict", "reason": "Archived article differs from its verified receipt"}
        path = run / "rendered" / article["rendered"]
        if not path.exists():
            body = "# Archived documentation\n\nThis source document or ordered part is absent from the latest repository snapshot. Its existing URL and last verified narrative are retained.\n\n[Current documentation library](" + renderer.article_url(state, "group:root") + ")\n\n---\n\n" + remote["content"]
            path.write_text(body, encoding="utf-8")
        article["content_sha256"] = sha(path.read_text(encoding="utf-8"))
        save(run / "state.json", state)
    content = (run / "rendered" / article["rendered"]).read_text(encoding="utf-8")
    return {"action": "update", "articleId": remote["id"], "summary": article["summary"],
            "content": content, "content_sha256": article["content_sha256"]}


def finish(run, home, dry_run=False):
    """Advance only complete verified receipts and report concurrent source changes."""
    run, home = Path(run), Path(home)
    state = read(run / "state.json")
    baseline = read(run / "baseline.json")
    pending = [article["key"] for article in state["articles"] if state["outcomes"].get(article["key"], {}).get("status") not in ("verified", "unchanged")]
    current = snapshot(Path(state["root"]), run / "finish-source-check",
                       {"files": {source["path"]: source for source in state["files"]}}, state["binding"])
    changed = sorted(path for path in set(state["inputs"]) | set(current["inputs"]) if state["inputs"].get(path) != current["inputs"].get(path))
    changed.extend(path for path, entry in state["configuration"].items()
                   if entry["sha256"] != current["configuration"].get(path, {}).get("sha256"))
    if not dry_run:
        for article in state["articles"]:
            key = article["key"]
            if state["outcomes"].get(key, {}).get("status") in ("verified", "unchanged"):
                baseline["articles"][key] = {"id": state["mapping"][key], "summary": article["summary"],
                                             "parent": article["parent"], "content_sha256": article["content_sha256"],
                                             "retired": bool(article.get("retired"))}
        if not pending:
            baseline["binding"] = state["binding"]
            baseline["files"] = {source["path"]: {key: source[key] for key in ("sha256", "text_sha256", "head", "snapshot")} for source in state["files"]}
            baseline["urls"] = state["urls"]
            active = home / "active.json"
            if read(active)["run"] != str(run):
                raise ValueError("Active sync changed before checkpoint completion")
            baseline_path = safe_path(home / "baseline.json", home)
            actual_bytes = baseline_path.read_bytes() if baseline_path.exists() else None
            actual_baseline = sha(actual_bytes) if actual_bytes is not None else None
            completed_bytes = (json.dumps(baseline, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            completed_already = actual_bytes == completed_bytes
            if actual_baseline != state["baseline_sha256"] and not completed_already:
                raise ValueError("Verified baseline changed during synchronization; preserve both receipts")
            if not completed_already:
                save(baseline_path, baseline)
            active.unlink()
            sync_directory(home)
    conflicts = [{"key": key, "id": state["mapping"].get(key), "reason": outcome.get("reason")} for key, outcome in state["outcomes"].items() if outcome.get("status") == "conflict"]
    report = {"complete": not dry_run and not pending and not changed,
              "dryRun": bool(dry_run), "root_url": state["urls"].get("group:root"),
              "source_documents": len(state["files"]), "pending": pending, "conflicts": conflicts,
              "changed_during_sync": changed, "link_warnings": state.get("link_warnings", []),
              "counts": {status: sum(outcome.get("status") == status for outcome in state["outcomes"].values()) for status in ("verified", "unchanged", "conflict")},
              "receipts": str(run / "receipts.jsonl")}
    if state["binding"].get("layout") == "project" and not dry_run and not pending:
        history = "group:project-history"
        report["project_history"] = {"id": state["mapping"][history], "url": state["urls"][history]}
    return report


def payload_init(run):
    """Allocate a private scratch payload without interpolating article text in a command."""
    directory = safe_path(Path(run) / "payloads", Path(run))
    ensure_directory(directory)
    descriptor, path = tempfile.mkstemp(prefix="payload-", suffix=".json", dir=str(directory))
    os.close(descriptor)
    return {"payload_file": path}


def payload_path(run, value):
    """Restrict scratch payloads to regular private files in the selected run."""
    path = Path(value)
    directory = Path(run) / "payloads"
    if path.parent != directory or not re.fullmatch(r"payload-[A-Za-z0-9_-]+\.json", path.name):
        raise ValueError("Payload file is outside the owned sync scratch directory")
    safe_path(path, Path(run))
    if not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError("Payload scratch file is missing")
    return path


def payload_append(run, value, chunk):
    """Append a bounded literal UTF-8 chunk to an existing private payload file."""
    path = payload_path(run, value)
    raw = chunk.encode("utf-8")
    if len(raw) > 40000 or path.stat().st_size + len(raw) > PAYLOAD_BYTES:
        raise ValueError("Connector payload exceeds its safe size limit")
    descriptor = os.open(str(path), os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "ab") as stream:
        stream.write(raw)
    return {"bytes": path.stat().st_size}


def main(argv=None):
    """Dispatch local snapshot and receipt operations with mandatory repository scope."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify", "prepare", "render", "catalog", "plan", "record", "assess", "finish", "lock", "payload-init", "payload-append"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run", type=Path)
    parser.add_argument("--key")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--payload")
    parser.add_argument("--payload-file", type=Path)
    parser.add_argument("--chunk", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--revision", help="Require the exact Git revision and zero link warnings for verify.")
    args = parser.parse_args(argv)
    try:
        root = repository(args.root)
        if args.command == "verify":
            result = verify(root, settings(root, local_verify=True), args.revision)
            print(json.dumps(result, ensure_ascii=False))
            return 0
        home = repository_state_dir(root)
        settings(root)
        if args.command == "lock":
            safe_path(home)
            ensure_directory(home)
            lock_path = safe_path(home / "coordinator.lock", home)
            descriptor = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
            with os.fdopen(descriptor, "w") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ValueError("A Knowledge Base sync already holds the coordinator lock") from None
                print('{"locked":true}', flush=True)
                for line in sys.stdin:
                    if line.strip() == "release":
                        break
            return 0
        if args.command == "prepare":
            result = prepare(root, home)
        else:
            run = owned_run(root, home, args.run or Path(read(home / "active.json")["run"]))
            if args.command == "render":
                result = render(run)
            elif args.command == "catalog":
                result = catalog(run, args.offset, args.limit)
            elif args.command == "plan":
                result = plan(run, args.key)
            elif args.command == "payload-init":
                result = payload_init(run)
            elif args.command == "payload-append":
                result = payload_append(run, args.payload_file, args.chunk)
            elif args.command == "finish":
                result = finish(run, home, args.dry_run)
            else:
                if args.payload_file is not None:
                    path = payload_path(run, args.payload_file)
                    if path.stat().st_size > PAYLOAD_BYTES:
                        raise ValueError("Connector payload exceeds its safe size limit")
                    payload = json.loads(path.read_text(encoding="utf-8"))
                    path.unlink()
                else:
                    payload = json.loads(args.payload) if args.payload is not None else json.load(sys.stdin)
                result = record(run, payload) if args.command == "record" else assess(run, payload)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, UnicodeError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print("Knowledge Base sync: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
