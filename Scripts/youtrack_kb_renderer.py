# copyright:begin
# File: Scripts/youtrack_kb_renderer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Render portable Markdown snapshots as navigable YouTrack article content.

This module performs no network operations and never evaluates source content.
Article identities and source bytes are supplied by the checkpoint engine.
"""

import collections
import hashlib
from html import escape
import json
from pathlib import Path
import posixpath
import re
from urllib.parse import parse_qs, quote, unquote, urlsplit


PART_BYTES = 22000
ARTICLE_BYTES = 30000

PROJECT_SECTIONS = (
    ("group:root", "Overview", "Find the project's guides, engineering reference and history."),
    ("group:guides", "Guides", "Set up the project and learn how to work on it."),
    ("group:engineering-reference", "Engineering Reference", "Find the project's engineering standards, tooling and validation practices."),
    ("group:project-history", "Project History", "Find the initialization record and approved, issue-linked task articles."),
)
def digest(value):
    """Return a stable UTF-8 digest for an exact rendered article body."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def indented_code(line):
    """Conservatively recognize a four-column code indent without parsing lists."""
    return line.startswith("    ") or re.match(r"^ {0,3}\t", line) is not None


def fence_marker(line):
    """Recognize a fence prefix only outside an indented code example."""
    if indented_code(line):
        return None
    return re.match(r"^ {0,3}(`{3,}|~{3,})", line)


def headings(text):
    """Locate ATX headings outside fences with source-compatible anchor names."""
    found = []
    seen = collections.Counter()
    fence = None
    offset = 0
    for line in text.splitlines(keepends=True):
        mark = fence_marker(line)
        if mark:
            token = mark[1]
            if fence is None:
                fence = token
            elif (token[0] == fence[0] and len(token) >= len(fence)
                  and not line[mark.end():].strip()):
                fence = None
        elif fence is None and not indented_code(line):
            match = re.match(r"^ {0,3}(#{1,6})\s+(.+?)(?:\s+#+)?\s*$", line.rstrip())
            if match:
                title = match[2]
                plain = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", title)
                slug = re.sub(r"[^\w\- ]", "", plain.lower().replace("`", "")).replace(" ", "-")
                number = seen[slug]
                seen[slug] += 1
                if number:
                    slug += "-" + str(number)
                found.append({"title": title, "slug": slug, "offset": offset, "level": len(match[1])})
        offset += len(line)
    return found


def readable_frontmatter(text):
    """Display leading YAML metadata without interpreting it as article markup."""
    if not text.startswith("---\n"):
        return text
    match = re.search(r"^\s*(?:---|\.\.\.)\s*$", text[4:], re.MULTILINE)
    if not match:
        raise ValueError("Unterminated Markdown frontmatter")
    metadata = text[4:4 + match.start()].rstrip("\n")
    fence = "`" * max(3, max((len(m[0]) + 1 for m in re.finditer(r"`{3,}", metadata)), default=3))
    return "## Source metadata\n\n" + fence + "yaml\n" + metadata + "\n" + fence + "\n\n" + text[4 + match.end():].lstrip("\n")


def reference_targets(text):
    """Collect document-wide reference destinations outside literal code examples."""
    targets = {}
    fence = None
    for line in text.splitlines(keepends=True):
        mark = fence_marker(line)
        if mark:
            token = mark[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not line[mark.end():].strip():
                fence = None
        elif fence is None and not indented_code(line):
            match = re.match(r"^ {0,3}\[([^\]]+)\]:\s*(\S.*)$", line.rstrip("\n"))
            if match:
                targets[match[1]] = match[2]
    return targets


def split_text(text):
    """Split exact source text at safe line boundaries outside fenced examples.

    Oversized indivisible lines or fenced/indented examples fail locally rather than
    dropping text or breaking examples. Offsets are character offsets.
    """
    if len(text.encode("utf-8")) <= PART_BYTES:
        return [(0, text)]
    parts = []
    start = 0
    offset = 0
    fence = None
    indentation = False
    safe = []
    for line in text.splitlines(keepends=True):
        mark = fence_marker(line)
        if fence is None:
            if indented_code(line):
                if not indentation and offset > start:
                    safe.append(offset)
                indentation = True
            elif line.strip():
                indentation = False
                if offset > start:
                    safe.append(offset)
            elif not indentation and offset > start:
                safe.append(offset)
        if mark:
            token = mark[1]
            if fence is None:
                fence = token
            elif (token[0] == fence[0] and len(token) >= len(fence)
                  and not line[mark.end():].strip()):
                fence = None
        offset += len(line)
        if len(text[start:offset].encode("utf-8")) > PART_BYTES:
            choices = [point for point in safe if point > start and len(text[start:point].encode("utf-8")) <= PART_BYTES]
            if not choices:
                raise ValueError("Markdown contains an oversized unsplittable line or fenced/indented example")
            cut = choices[-1]
            parts.append((start, text[start:cut]))
            start = cut
            safe = [point for point in safe if point > cut]
            if len(text[start:offset].encode("utf-8")) > PART_BYTES:
                raise ValueError("Markdown contains an oversized unsplittable line or fenced/indented example")
    if start < len(text):
        parts.append((start, text[start:]))
    if "".join(body for _, body in parts) != text:
        raise ValueError("Markdown split did not preserve its complete source")
    return parts


def repository_sections(inventory):
    """Build the existing mirror indexes from every published source directory."""
    articles = [{"key": "group:root", "summary": inventory["binding"]["root_title"], "parent": None, "kind": "root"}]
    directories = set()
    for source in inventory["files"]:
        parent = Path(source["path"]).parent
        while parent.as_posix() != ".":
            directories.add(parent.as_posix())
            parent = parent.parent
    for directory in sorted(directories, key=lambda value: (value.count("/"), value)):
        parent = posixpath.dirname(directory)
        articles.append({"key": "directory:" + directory, "summary": directory,
                         "parent": "directory:" + parent if parent else "group:root",
                         "kind": "directory", "path": directory})
    return articles


def build(inventory, run):
    """Create parent-first library, document and ordered-part identities."""
    run = Path(run)
    project_layout = inventory["binding"].get("layout") == "project"
    if project_layout:
        articles = [{"key": key, "summary": title, "description": description,
                     "parent": None, "kind": "section"} for key, title, description in PROJECT_SECTIONS]
        sources = {source["path"]: source for source in inventory["files"]}
        project_guides = inventory["binding"]["project_guides"]
        ordered_sources = [sources[path] for path in project_guides]
    else:
        articles = repository_sections(inventory)
        ordered_sources = inventory["files"]
    chunks = []
    chunk_dir = run / "chunks"
    chunk_dir.mkdir(mode=0o700, exist_ok=True)
    for source in ordered_sources:
        path = source["path"]
        text = readable_frontmatter((run / "sources" / source["snapshot_file"]).read_text(encoding="utf-8"))
        source["headings"] = headings(text)
        source["references"] = reference_targets(text)
        key = "file:" + path
        if project_layout:
            parent, summary = project_guides[path]
            part_title = summary
        else:
            title = next((heading["title"] for heading in source["headings"] if heading["level"] == 1), Path(path).stem)
            title = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", title).replace("`", "")
            title = re.sub(r"\s+", " ", title).strip()
            directory = posixpath.dirname(path)
            parent = "directory:" + directory if directory else "group:root"
            summary = (title[:120] + " — " + path)[-240:]
            part_title = Path(path).name[:160]
        pieces = split_text(text)
        articles.append({"key": key, "summary": summary, "parent": parent,
                         "kind": "file", "path": path, "split": len(pieces) > 1})
        for number, (offset, body) in enumerate(pieces, 1):
            part_key = key if len(pieces) == 1 else key + ":part:" + str(number)
            if len(pieces) > 1:
                articles.append({"key": part_key, "summary": (part_title + " — Part " + str(number))[:240],
                                 "parent": key, "kind": "part", "path": path,
                                 "part": number, "parts": len(pieces), "offset": offset})
            filename = str(len(chunks)).zfill(5) + ".md"
            (chunk_dir / filename).write_text(body, encoding="utf-8")
            chunks.append({"key": part_key, "path": path, "file": filename,
                           "offset": offset, "end": offset + len(body)})
    return articles, chunks


def article_url(state, key):
    """Use recorded article URLs or unpublished placeholders during preparation."""
    if key in state.get("urls", {}):
        return state["urls"][key]
    root_url = state.get("urls", {}).get("group:root")
    identifier = state.get("mapping", {}).get(key)
    if root_url and identifier:
        return root_url.rsplit("/", 1)[0] + "/" + quote(identifier, safe="")
    return "kb://pending/" + quote(key, safe="")


def source_url(state, path, directory=False, line=None):
    """Link only configured repository paths that existed at the recorded revision."""
    base = state["binding"].get("source_url")
    head = state.get("head")
    versioned = set(state.get("versioned_paths", []))
    exists = any(item.startswith(path.rstrip("/") + "/") for item in versioned) if directory else path in versioned
    if not base or not head or not exists:
        return None
    result = base + ("/tree/" if directory else "/blob/") + head + "/" + quote(path, safe="/")
    return result + "#L" + str(line) if line else result


def destination(state, raw, current, warnings, statistics):
    """Resolve documentation links without inventing external source destinations."""
    raw = raw.strip()
    suffix = ""
    site_path = None
    literal = re.fullmatch(
        r"\{\{\s*(['\"])(/[^'\"{}]*)\1\s*\|\s*relative_url\s*\}\}"
        r"(\s+(?:\"[^\"]*\"|'[^']*'))?", raw)
    if "{{" in raw or "{%" in raw:
        if not current.startswith("Docs/Site/") or not literal:
            warnings.append({"source": current, "target": raw, "reason": "unsupported Liquid link"})
            return None
        target, suffix = literal[2], literal[3] or ""
        route = urlsplit(target)
        if route.netloc:
            warnings.append({"source": current, "target": raw, "reason": "site link must use a local output path"})
            return None
        relative = unquote(route.path).lstrip("/")
        site_path = posixpath.normpath(posixpath.join("Docs/Site", relative or "index.md"))
        if site_path != "Docs/Site" and not site_path.startswith("Docs/Site/"):
            warnings.append({"source": current, "target": raw, "reason": "site link escapes documentation site"})
            return None
        tracked = set(state.get("tracked", []))
        files = {item["path"] for item in state["files"]}
        if site_path.endswith(".html") and site_path not in tracked:
            markdown = site_path[:-5] + ".md"
            if markdown in files:
                site_path = markdown
    elif raw.startswith("<") and ">" in raw:
        end = raw.index(">")
        target, suffix = raw[1:end], raw[end + 1:]
    else:
        match = re.match(r"(\S+)(\s+[\"\x27].*)?$", raw)
        target, suffix = (match[1], match[2] or "") if match else (raw, "")
    target = target.replace("\\(", "(").replace("\\)", ")")
    parsed = urlsplit(target)
    line = None
    if site_path is not None:
        path = site_path
    elif parsed.scheme in ("air-file", "air-folder", "file"):
        root = state["root"].rstrip("/")
        absolute = unquote(parsed.path)
        if absolute == root:
            path = ""
        elif absolute.startswith(root + "/"):
            path = absolute[len(root) + 1:]
        else:
            warnings.append({"source": current, "target": target, "reason": "outside-repository local reference"})
            return None
        data = parse_qs(parsed.query).get("linesData")
        if data:
            try:
                line = json.loads(data[0])["lines"]["first"] + 1
            except (ValueError, KeyError, TypeError):
                pass
    elif parsed.scheme or target.startswith("//"):
        return raw
    elif parsed.path:
        path = posixpath.normpath(posixpath.join(posixpath.dirname(current), unquote(parsed.path)))
    else:
        path = current
    if path == ".":
        path = ""
    if path == ".." or path.startswith("../") or path.startswith("/"):
        warnings.append({"source": current, "target": target, "reason": "outside-repository reference"})
        return None
    files = {item["path"]: item for item in state["files"]}
    keys = {item["key"] for item in state["articles"]}
    if path in files:
        key = "file:" + path
        if parsed.fragment:
            heading = next((item for item in files[path]["headings"] if item["slug"] == unquote(parsed.fragment)), None)
            if heading:
                part = next((item for item in state["chunks"] if item["path"] == path and item["offset"] <= heading["offset"] < item["end"]), None)
                if part:
                    key = part["key"]
            statistics["section_links"] += 1
        statistics["article_links"] += 1
        return article_url(state, key) + suffix
    directory_key = "directory:" + path if path else "group:root"
    if directory_key in keys:
        statistics["directory_links"] += 1
        return article_url(state, directory_key) + suffix
    supporting = path in state.get("tracked", [])
    is_directory = any(item.startswith(path.rstrip("/") + "/") for item in state.get("tracked", []))
    url = source_url(state, path, is_directory, line)
    if url:
        statistics["source_links"] += 1
        return url + ("#" + parsed.fragment if parsed.fragment and line is None else "") + suffix
    reason = "supporting source has no published repository URL" if supporting or is_directory else "unresolved local reference"
    warnings.append({"source": current, "target": target, "reason": reason})
    return None


def rewrite_links(state, text, current, warnings, statistics):
    """Rewrite inline/reference destinations while retaining literal code examples."""
    source = next(value for value in state["files"] if value["path"] == current)
    unsupported = {label: target for label, target in source.get("references", {}).items()
                   if destination(state, target, current, [], collections.Counter()) is None}

    def rewrite_line(line):
        """Rewrite navigable destinations in one non-code line fragment."""
        reference = re.match(r"^(\s{0,3}\[[^\]]+\]:\s*)(.*)$", line.rstrip("\n"))
        if reference:
            result = destination(state, reference[2], current, warnings, statistics)
            if result is None:
                label = re.search(r"\[([^\]]+)\]", reference[1])[1]
                return "Reference `" + label + "`: source path `" + reference[2].replace("\n", " ") + "`." + ("\n" if line.endswith("\n") else "")
            return reference[1] + result + ("\n" if line.endswith("\n") else "")
        for label, target in unsupported.items():
            line = re.sub(r"!?\[([^\]]+)\]\[" + re.escape(label) + r"\]",
                          lambda match: match[1] + " (source path: " + target + ")", line, flags=re.IGNORECASE)
            line = re.sub(r"!?\[" + re.escape(label) + r"\](?:\[\])?(?![\[(])",
                          lambda match: label + " (source path: " + target + ")", line, flags=re.IGNORECASE)
        output = ""
        offset = 0
        while True:
            marker = line.find("](", offset)
            if marker < 0:
                return output + line[offset:]
            depth, index, escaped = 1, marker + 2, False
            while index < len(line) and depth:
                character = line[index]
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                index += 1
            if depth:
                return output + line[offset:]
            raw = line[marker + 2:index - 1]
            rewritten = destination(state, raw, current, warnings, statistics)
            if rewritten is None:
                label_start = line.rfind("[", offset, marker)
                if label_start < 0:
                    output += line[offset:index]
                else:
                    prefix = line[offset:label_start]
                    if prefix.endswith("!"):
                        prefix = prefix[:-1]
                    label = line[label_start + 1:marker]
                    output += prefix + label + " (source path: " + raw + ")"
            else:
                output += line[offset:marker + 2] + rewritten + ")"
            offset = index

    result = []
    fence = None
    for line in text.splitlines(keepends=True):
        mark = fence_marker(line)
        if mark:
            token = mark[1]
            if fence is None:
                fence = token
            elif (token[0] == fence[0] and len(token) >= len(fence)
                  and not line[mark.end():].strip()):
                fence = None
            result.append(line)
        elif fence is not None or indented_code(line):
            result.append(line)
        else:
            position = 0
            for match in re.finditer(r"(`+)(.*?)(?<!`)\1(?!`)", line):
                result.append(rewrite_line(line[position:match.start()]))
                result.append(match[0])
                position = match.end()
            result.append(rewrite_line(line[position:]))
    return "".join(result)


def article_links(state, articles):
    """List managed article titles and their verified destinations when available."""
    return "".join(
        "- [" + article["summary"].replace("[", "\\[").replace("]", "\\]") + "](" + article_url(state, article["key"]) + ")\n"
        for article in articles
    )


def overview_intro(state):
    """Format snapshot metadata as plain paragraphs without Markdown links or HTML."""
    metadata = state["binding"]["overview"]
    return "".join(
        re.sub(r"([\\`*_[\]{}#!|~+()\-])", r"\\\1", escape(value, quote=False)) + "\n\n"
        for value in (metadata["name"], metadata["description"]) if value
    )


def render(state, run):
    """Write bounded article bodies and return source/link-qualified article records."""
    run = Path(run)
    directory = run / "rendered"
    directory.mkdir(mode=0o700, exist_ok=True)
    files = {item["path"]: item for item in state["files"]}
    chunks = {item["key"]: item for item in state["chunks"]}
    project_layout = state["binding"].get("layout") == "project"
    navigation_root = "[Overview]" if project_layout else "[Documentation library]"
    warnings = []
    statistics = collections.Counter()
    for number, article in enumerate(state["articles"]):
        key = article["key"]
        if article.get("retired"):
            continue
        navigation = navigation_root + "(" + article_url(state, "group:root") + ")"
        if article["parent"] and article["parent"] != "group:root":
            navigation += " · [Parent](" + article_url(state, article["parent"]) + ")"
        if article["kind"] == "section":
            root_section = key == "group:root"
            body = "" if root_section else navigation + "\n\n"
            body += "# " + article["summary"] + "\n\n"
            if root_section:
                body += overview_intro(state)
            body += article["description"] + "\n\n"
            body += article_links(state, (
                child for child in state["articles"] if not child.get("retired") and (
                    child["parent"] == key or (root_section and child["kind"] == "section" and child["key"] != key)
                )
            ))
        elif article["kind"] in ("root", "directory"):
            body = navigation + "\n\n# " + article["summary"] + "\n\n"
            if article["kind"] == "root":
                body += "Repository Markdown synchronized from its recorded working-copy snapshot. Repository sources remain authoritative. Historical plans and evidence retain their original qualification.\n\n"
                body += "Namespace UUID: `" + state["binding"]["namespace_uuid"] + "`.\n\n"
            body += article_links(state, (child for child in state["articles"] if child["parent"] == key and not child.get("retired")))
        else:
            source = files[article["path"]]
            path = source["path"]
            url = source_url(state, path)
            label = "[" + path + "](" + url + ")" if url else "`" + path + "`"
            qualification = "Working-copy snapshot; differs from the linked base revision." if source["dirty"] else "Matches the recorded repository revision."
            body = navigation + "\n\n> Source: " + label + "  \n> Source SHA-256: `" + source["sha256"] + "`  \n> " + qualification + "\n\n"
            if article["kind"] == "file" and article.get("split"):
                body += "# " + article["summary"] + "\n\nThis document is available in ordered parts.\n\n"
                for child in state["articles"]:
                    if child["parent"] == key:
                        body += "- [" + child["summary"] + "](" + article_url(state, child["key"]) + ")\n"
            else:
                chunk = chunks[key]
                raw = (run / "chunks" / chunk["file"]).read_text(encoding="utf-8")
                body += rewrite_links(state, raw, path, warnings, statistics)
                if article["kind"] == "part":
                    original = (run / "sources" / source["snapshot_file"]).read_text(encoding="utf-8")
                    definitions = []
                    fence = None
                    for line in original.splitlines(keepends=True):
                        mark = fence_marker(line)
                        if mark:
                            token = mark[1]
                            if fence is None:
                                fence = token
                            elif (token[0] == fence[0] and len(token) >= len(fence)
                                  and not line[mark.end():].strip()):
                                fence = None
                        elif (fence is None and not indented_code(line)
                              and re.match(r"^ {0,3}\[[^\]]+\]:\s*\S", line)):
                            definitions.append(line)
                    if definitions:
                        body += "\n\n" + rewrite_links(state, "".join(definitions), path, warnings, statistics)
                    body += "\n\n[Document contents](" + article_url(state, article["parent"]) + ")\n"
        if len(body.encode("utf-8")) > ARTICLE_BYTES:
            raise ValueError("Rendered article exceeds the safe size limit: " + key)
        filename = str(number).zfill(5) + ".md"
        (directory / filename).write_text(body, encoding="utf-8")
        article.update(rendered=filename, content_sha256=digest(body), bytes=len(body.encode("utf-8")))
    state["link_warnings"] = warnings
    state["link_stats"] = dict(statistics)
    return state
