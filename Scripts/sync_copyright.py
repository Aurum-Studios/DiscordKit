#!/usr/bin/env python3
# copyright:begin
# File: Scripts/sync_copyright.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Check or update Git-tracked copyright comments from editable COPYRIGHT.md."""

import argparse
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


SETTINGS = re.compile(
    r"<!-- copyright:settings -->\s*```json\s*\n(.*?)\n```\s*<!-- /copyright:settings -->",
    re.DOTALL,
)
HASH_SUFFIXES = {".py", ".sh", ".bash", ".zsh", ".yml", ".yaml", ".toml", ".ini", ".cfg", ".conf", ".properties", ".neon", ".rb", ".ps1"}
SLASH_SUFFIXES = {".swift", ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".cs", ".java", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".kt", ".kts", ".gradle", ".go", ".rs", ".php"}
HTML_SUFFIXES = {".md", ".markdown", ".html", ".htm", ".xml", ".svg"}
HASH_NAMES = {".gitignore", "gitignore", ".gitattributes", ".gitmodules", ".editorconfig", "editorconfig", "Makefile", "Dockerfile", "Gemfile", "Rakefile"}


def load_policy(content):
    """Parse one settings block and reject missing, unknown or unsafe values.

    Accept UTF-8 bytes or text. Return the five required settings. Invalid
    encodings, JSON, years, URLs and repository-relative exclusion globs raise
    ValueError; no filesystem or clock state influences the notice.
    """
    text = content.decode("utf-8") if isinstance(content, bytes) else content
    matches = list(SETTINGS.finditer(text))
    if (len(matches) != 1 or text.count("<!-- copyright:settings -->") != 1
            or text.count("<!-- /copyright:settings -->") != 1):
        raise ValueError("COPYRIGHT.md needs exactly one copyright:settings JSON block")
    policy = json.loads(matches[0].group(1))
    if not isinstance(policy, dict) or set(policy) != {"creator", "years", "holder", "website", "exclude"}:
        raise ValueError("copyright settings must contain creator, years, holder, website and exclude only")
    for key in ("creator", "years", "holder", "website"):
        value = policy[key]
        if (not isinstance(value, str) or not value.strip() or value != value.strip() or not value.isprintable()
                or re.search(r"[\x00-\x1f\x7f<>]", value)
                or any(marker in value for marker in ("--", "/*", "*/", "<?", "?>"))):
            raise ValueError("invalid copyright setting: " + key)
    years = re.fullmatch(r"([1-9][0-9]{3})(?:-([1-9][0-9]{3}))?", policy["years"])
    if not years or (years.group(2) and years.group(1) > years.group(2)):
        raise ValueError("years must be YYYY or an ordered YYYY-YYYY range")
    website = urlsplit(policy["website"])
    if (website.scheme != "https" or not website.netloc or website.username
            or website.password or any(character.isspace() for character in policy["website"])):
        raise ValueError("website must be an absolute HTTPS URL without credentials")
    exclusions = policy["exclude"]
    if not isinstance(exclusions, list):
        raise ValueError("exclude must be a list of repository-relative globs")
    for pattern in exclusions:
        if (not isinstance(pattern, str) or not pattern.strip() or not pattern.isprintable() or pattern.startswith("/")
                or ".." in pattern.split("/") or "\\" in pattern
                or re.search(r"[\x00-\x1f\x7f]", pattern)):
            raise ValueError("invalid copyright exclusion glob")
    return policy


def source_path(path):
    """Return the underlying source name without template/distribution wrappers."""
    path = Path(path)
    while path.suffix in (".tmpl", ".dist"):
        path = path.with_suffix("")
    return path


def comment_style(path):
    """Return a safe native comment style, or None for centrally covered formats."""
    path = source_path(path)
    suffix = path.suffix.lower()
    if path.name in HASH_NAMES or suffix in HASH_SUFFIXES:
        return "#"
    if suffix in SLASH_SUFFIXES:
        return "//"
    if suffix in HTML_SUFFIXES:
        return "html"
    if suffix in (".css", ".scss"):
        return "block"
    return None


def split_preamble(path, text):
    """Separate mandatory first lines without altering BOMs or newline bytes.

    Preserve Markdown frontmatter, script/encoding headers, SwiftPM's tools
    directive, XML declarations, single-line doctypes and PHP opening tags. Unterminated
    Markdown frontmatter fails rather than moving metadata into page content.
    """
    prefix = "\ufeff" if text.startswith("\ufeff") else ""
    text = text[len(prefix):]
    lines = text.splitlines(keepends=True)
    logical = source_path(path)
    if logical.suffix.lower() == ".php":
        opening = re.match(r"<\?php(?=\s|$)(?:\r?\n)?", text)
        if opening:
            return prefix + opening.group(), text[opening.end():]
    if logical.suffix.lower() in (".css", ".scss"):
        charset = re.match(r'''@charset[ \t]+["'][^"'\r\n]+["'];[ \t]*(?:\r?\n)?''', text)
        if charset:
            return prefix + charset.group(), text[charset.end():]
    if logical.name == "Dockerfile":
        count = 0
        for line in lines:
            if not re.match(r"^[ \t]*#[ \t]*(?:syntax|escape|check)[ \t]*=", line, re.IGNORECASE):
                break
            count += 1
        if count:
            return prefix + "".join(lines[:count]), "".join(lines[count:])
    if logical.suffix.lower() in (".md", ".markdown") and lines and lines[0].strip() == "---":
        end = next((index + 1 for index, line in enumerate(lines[1:], 1) if line.strip() == "---"), None)
        if end is None:
            raise ValueError("unterminated Markdown frontmatter: " + str(path))
        return prefix + "".join(lines[:end]), "".join(lines[end:])
    if re.match(r"<\?xml\s", text):
        end = text.find("?>")
        if end < 0:
            raise ValueError("unterminated XML declaration: " + str(path))
        end += 2
        if text[end:].startswith("\r\n"):
            end += 2
        elif text[end:].startswith("\n"):
            end += 1
        return prefix + text[:end], text[end:]
    count = 0
    for index, line in enumerate(lines[:2]):
        if ((index == 0 and (line.startswith(("#!", "// swift-tools-version:"))
                            or (line.startswith(("<!DOCTYPE", "<!doctype")) and line.rstrip().endswith(">"))))
                or (index <= 1 and re.match(r"^[ \t]*#.*?coding[:=][ \t]*[-\w.]+", line))):
            count = index + 1
        else:
            break
    return prefix + "".join(lines[:count]), "".join(lines[count:])


def strip_notice(body, style):
    """Remove only the leading owned notice; reject a truncated managed block."""
    opening, closing = {
        "html": ("<!-- copyright:begin", "copyright:end -->"),
        "block": ("/* copyright:begin", "copyright:end */"),
        "#": ("# copyright:begin", "# copyright:end"),
        "//": ("// copyright:begin", "// copyright:end"),
    }[style]
    if not body.startswith(opening):
        return body
    match = re.match(re.escape(opening) + r"\r?\n.*?\r?\n" + re.escape(closing) + r"(?:\r?\n){1,2}", body, re.DOTALL)
    if not match:
        raise ValueError("malformed leading copyright:begin/end block")
    return body[match.end():]


def update_notice(path, content, policy):
    """Return bytes with the leading managed notice replaced or safely inserted.

    Preserve unsupported/binary content, excluded ownership and independent
    existing notices. Do not change body text, frontmatter, BOM or newline style.
    Paths that cannot be safely represented in comments remain centrally covered.
    """
    name = Path(path).as_posix()
    style = comment_style(name)
    if (not style or any(fnmatch.fnmatchcase(name, pattern) for pattern in policy["exclude"])
            or not name.isprintable() or any(value in name for value in ("-->", "*/"))
            or (style == "html" and "--" in name)):
        return content
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    if "\0" in text:
        return content
    if source_path(path).suffix.lower() == ".php" and not re.match(r"\ufeff?<\?php(?:\s|$)", text):
        return content
    newline = "\r\n" if "\r\n" in text else "\n"
    preamble, body = split_preamble(name, text)
    original_body = body
    body = strip_notice(body, style)
    if body == original_body and re.search(
            r"(?im)^\s*(?://|#|/\*+|\*|<!--)?\s*(?:Copyright\b|©|SPDX-(?:FileCopyrightText|License-Identifier):)",
            "\n".join(body.splitlines()[:30])):
        return content
    lines = ["File: " + name, "Created by " + policy["creator"] + ".",
             "Copyright (c) " + policy["years"] + " " + policy["holder"] + ".", policy["website"]]
    if style in ("html", "block"):
        opening, closing = ("<!--", "-->") if style == "html" else ("/*", "*/")
        lines = [opening + " copyright:begin", *lines, "copyright:end " + closing]
    else:
        lines = [style + " copyright:begin", *(style + " " + line for line in lines), style + " copyright:end"]
    separator = newline if preamble and not preamble.endswith(("\n", "\ufeff")) else ""
    return (preamble + separator + newline.join(lines) + newline * 2 + body).encode("utf-8")


def render_files(files, aliases=None):
    """Apply one policy to a complete in-memory file map before any generator write.

    Optional aliases map source paths to their logical generated names. Inputs
    are not mutated. COPYRIGHT.md is required; format/ownership exceptions keep
    their bytes and remain governed centrally by that file's policy.
    """
    policy = load_policy(files[Path("COPYRIGHT.md")])
    aliases = aliases or {}
    return {path: update_notice(aliases.get(path, path), content, policy) for path, content in files.items()}


def strip_composed_notices(content):
    """Remove managed hash-comment metadata when composing root ignore fragments.

    Input/output are UTF-8 bytes. Only complete comment-only managed blocks are
    removed; ignore rules and independent comments retain their exact bytes.
    The caller reapplies a single root notice after composition and rendering.
    """
    pattern = rb"(?m)^# copyright:begin\r?\n(?:#[^\r\n]*\r?\n)*?# copyright:end(?:\r?\n){1,2}"
    return re.sub(pattern, b"", content)


def tracked_files(root):
    """Read index paths/modes at the exact Git root; reject conflicts and traversal.

    Use NUL-delimited Git output so spaces and unusual names cannot become shell
    code. Return (relative Path, mode) pairs without reading symlink/submodule
    targets. This performs read-only Git operations and never changes the index.
    """
    top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True)
    if Path(top.stdout.strip()).resolve() != root:
        raise ValueError("--root must be the exact Git repository root")
    result = subprocess.run(["git", "-C", str(root), "ls-files", "--stage", "-z"], check=True, capture_output=True)
    paths = []
    for entry in result.stdout.split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, _object, stage = metadata.decode("ascii").split()
        name = raw_name.decode("utf-8")
        relative = Path(name)
        if stage != "0":
            raise ValueError("unmerged Git path: " + name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe tracked path: " + name)
        paths.append((relative, mode))
    return paths


def safe_file(root, relative):
    """Validate every path component before reading a regular tracked file."""
    target = root / relative
    for path in (target, *target.parents):
        if path == root:
            break
        if path.is_symlink():
            raise ValueError("symlink in tracked file path: " + str(relative))
    if not target.is_file():
        raise ValueError("tracked file is missing or not regular: " + str(relative))
    return target


def synchronize(root, apply=False, aliases=None, overrides=None):
    """Preflight the complete tracked tree, report counts, and optionally update it.

    Overrides support a toolkit's canonical policy mirror and must name tracked
    regular files. Check never writes; apply preserves modes by updating files
    in place. Filesystem errors can interrupt apply after earlier writes; rerun
    after repair. Return changed relative paths, leaving Git staging untouched.
    """
    root = Path(root).resolve()
    entries = tracked_files(root)
    files = {}
    retained = 0
    for relative, mode in entries:
        if mode in ("120000", "160000"):
            retained += 1
            continue
        files[relative] = safe_file(root, relative).read_bytes()
    if Path("COPYRIGHT.md") not in files:
        raise ValueError("COPYRIGHT.md must be tracked before synchronization")
    inputs = dict(files)
    for relative, content in (overrides or {}).items():
        if relative not in files:
            raise ValueError("override is not a tracked regular file: " + str(relative))
        inputs[relative] = content
    rendered = render_files(inputs, aliases)
    changed = [path for path in files if files[path] != rendered[path]]
    inline = sum(b"copyright:begin" in content[:4096] for content in rendered.values())
    print("Copyright coverage: " + str(inline) + " inline, " + str(len(files) - inline) + " central/independent, " + str(retained) + " symlinks/submodules retained.")
    for path in changed:
        print(("Update: " if apply else "Drift: ") + str(path))
    if apply:
        for path in changed:
            safe_file(root, path).write_bytes(rendered[path])
    return changed


def main(argv=None):
    """Check by default, or apply working-file updates with --apply; return 0/1."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="exact Git repository root")
    parser.add_argument("--apply", action="store_true", help="update working files after complete preflight")
    arguments = parser.parse_args(argv)
    try:
        changed = synchronize(arguments.root, arguments.apply)
        return int(bool(changed) and not arguments.apply)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("sync-copyright: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
