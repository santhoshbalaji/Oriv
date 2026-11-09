#!/usr/bin/env python3
"""Check tracked working files or every tree, patch and message in an outgoing range.

An optional ignored .publication-denylist holds one literal term per line (case
insensitive); blank lines and lines starting with # are ignored. Diagnostics omit
matched values so a failed CI run does not repeat private content in its logs.
"""

import argparse
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import sys
import zlib


EMAIL = re.compile(r"[A-Z0-9_.+%\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)
HOME_PATH = re.compile(r"/(?:Users|home)/|/(?:var/|private/var/)?root/|[A-Z]:\\Users\\|(?<![\w])~[/\\]", re.I)
TEAM = r"(?:DEVELOPMENT_TEAM|DevelopmentTeam|teamID)"
TEAM_ASSIGNMENT = re.compile(
    rf"(?<![\w]){TEAM}(?:[\"']|\[[^\]\n]*\])?[ \t]*[:=][ \t]*([^\n]*)"
)
TEAM_XML = re.compile(rf"<key>\s*{TEAM}\s*</key>\s*<(string|integer)>(.*?)</\1>", re.S)
LOCAL_TEAM_REFERENCES = {"$ORIV_DEVELOPMENT_TEAM", "${ORIV_DEVELOPMENT_TEAM}", "$(ORIV_DEVELOPMENT_TEAM)"}
SECRET_PATTERNS = {
    "private key": r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----",
    "cloud access key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "GitHub token": r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b",
    "Slack token": r"\bxox[baprs]-[A-Za-z0-9-]{16,}\b",
    "API token": r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b",
    "Google API key": r"\bAIza[A-Za-z0-9_-]{30,}\b",
    "Stripe secret": r"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b",
    "JWT credential": r"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
    "credential literal": r'''(?i)(?:api[_-]?key|client[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key)["']?\s*[:=]\s*["'][A-Za-z0-9_+/.=\-]{16,}["']''',
}
SECRETS = {rule: re.compile(pattern) for rule, pattern in SECRET_PATTERNS.items()}
PRIVATE_SUFFIXES = {".p12", ".pfx", ".p8", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".cer", ".der"}
PRIVATE_NAMES = {".publication-denylist", "credentials", "credentials.json", "secrets.json", "secrets.yml", "secrets.yaml", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"}


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def allowed_email(value):
    local, domain = value.casefold().rsplit("@", 1)
    return (local in {"noreply", "no-reply"}
            or domain in {"users.noreply.github.com", "noreply.github.com"}
            or re.fullmatch(r"(?:[a-z0-9-]+\.)*example\.[a-z.]+", domain) is not None)


def team_value(value):
    value = value.strip()
    if value.startswith(("'", '"')):
        quoted = re.match(r'''(["'])(.*?)\1''', value)
        return quoted.group(2) if quoted else value
    return re.split(r"[;,#}]|\s+//", value, maxsplit=1)[0].strip()


def check_text(label, text, denylist, findings):
    def record(offset, rule):
        findings.add((label, text.count("\n", 0, offset) + 1, rule))

    for match in HOME_PATH.finditer(text):
        record(match.start(), "personal home path")
    for match in EMAIL.finditer(text):
        if not allowed_email(match.group()):
            record(match.start(), "non-example, non-noreply email")
    for match in TEAM_ASSIGNMENT.finditer(text):
        if team_value(match.group(1)) not in {"", *LOCAL_TEAM_REFERENCES}:
            record(match.start(), "non-empty team setting")
    for match in TEAM_XML.finditer(text):
        if match.group(2).strip():
            record(match.start(), "non-empty team setting")
    for rule, regex in SECRETS.items():
        for match in regex.finditer(text):
            record(match.start(), rule)
    folded = text.casefold()
    for term in denylist:
        start = 0
        while (offset := folded.find(term, start)) >= 0:
            record(offset, "local denylist term")
            start = offset + len(term)


def check_file(label, name, raw, denylist, findings):
    path = PurePosixPath(name)
    if (path.suffix.casefold() in PRIVATE_SUFFIXES
            or path.name.casefold() in PRIVATE_NAMES
            or any(part.casefold() in {".aws", ".ssh"} for part in path.parts)
            or path.name.casefold() == ".env" or path.name.casefold().startswith(".env.")
            or name.casefold() == "config/local.xcconfig"):
        findings.add((label, 1, "local configuration or credential file"))
    check_text(label + " (filename)", name, denylist, findings)
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        # Scan actual PNG metadata, including compressed text, rather than
        # interpreting compressed pixel bytes as accidental paths or emails.
        offset = 8
        while offset < len(raw):
            size = int.from_bytes(raw[offset:offset + 4], "big")
            kind = raw[offset + 4:offset + 8]
            chunk = raw[offset + 8:offset + 8 + size]
            if offset + size + 12 > len(raw):
                raise ValueError("Invalid PNG metadata")
            if kind == b"tEXt":
                check_text(label, chunk.decode("latin-1"), denylist, findings)
            elif kind == b"zTXt":
                keyword, body = chunk.split(b"\0", 1)
                if body[0] != 0:
                    raise ValueError("Unsupported PNG text compression")
                check_text(label, (keyword + b"\0" + zlib.decompress(body[1:])).decode("latin-1"), denylist, findings)
            elif kind == b"iTXt":
                keyword, body = chunk.split(b"\0", 1)
                compressed, method = body[:2]
                language, translated, body = body[2:].split(b"\0", 2)
                if compressed not in (0, 1) or method != 0:
                    raise ValueError("Unsupported PNG text compression")
                if compressed:
                    body = zlib.decompress(body)
                check_text(label, b"\n".join((keyword, language, translated, body)).decode("utf-8"), denylist, findings)
            elif kind == b"eXIf":
                check_text(label, chunk.decode("latin-1"), denylist, findings)
            offset += size + 12
    elif raw.startswith(b"bplist00"):
        # Binary plists do not expose their key/value relationships as text.
        def visit(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    if key in {"DEVELOPMENT_TEAM", "DevelopmentTeam", "teamID"} and child:
                        findings.add((label, 1, "non-empty team setting"))
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
            elif isinstance(value, str):
                check_text(label, value, denylist, findings)
        visit(plistlib.loads(raw))
    else:
        encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8"
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError:
            text = b"\n".join(re.findall(rb"[\x20-\x7e]{12,}", raw)).decode("ascii")
        check_text(label, text, denylist, findings)


def scan_working_tree(root, denylist, findings):
    paths = git("ls-files", "-z").split(b"\0")
    count = 0
    for item in paths:
        if not item:
            continue
        name = os.fsdecode(item)
        path = root / name
        if path.is_symlink():
            raw = os.fsencode(os.readlink(path))
        else:
            raw = path.read_bytes()
        check_file(name, name, raw, denylist, findings)
        count += 1
    return f"{count} tracked working files"


def scan_range(revision_range, denylist, findings):
    commits = git("rev-list", "--reverse", "--topo-order", "--end-of-options", revision_range).decode().splitlines()
    for commit in commits:
        # Include author/committer identities as well as the full message.
        metadata = git("show", "-s", "--format=%an <%ae>%n%cn <%ce>%n%B", commit).decode(errors="replace")
        check_text(f"{commit[:12]} message/identities", metadata, denylist, findings)
        for row in git("ls-tree", "-rz", commit).split(b"\0"):
            if not row:
                continue
            info, filename = row.split(b"\t", 1)
            mode, kind, oid = info.split()
            name = os.fsdecode(filename)
            if kind != b"blob":
                findings.add((f"{commit[:12]}:{name}", 1, "unscanned submodule"))
                continue
            check_file(f"{commit[:12]}:{name}", name, git("cat-file", "blob", oid.decode()), denylist, findings)
        patch = git("diff-tree", "--root", "-m", "-p", "--no-ext-diff", "--no-textconv", "--no-renames", "--format=", commit).decode(errors="replace")
        # Scan additions, deletions and context, including multi-line plist keys.
        content = "\n".join(line[1:] if line.startswith(("+", "-", " ")) else line for line in patch.splitlines())
        check_text(f"{commit[:12]} patch", content, denylist, findings)
    return f"{len(commits)} outgoing commits (full trees, patches, messages and identities)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--range", dest="revision_range", help="Git revision range, or a tip for all reachable history")
    args = parser.parse_args()
    try:
        root = Path(os.fsdecode(git("rev-parse", "--show-toplevel").strip()))
        os.chdir(root)
        denyfile = root / ".publication-denylist"
        denylist = []
        if denyfile.exists():
            if denyfile.is_symlink():
                raise ValueError("The local denylist must be a regular file")
            if subprocess.run(["git", "check-ignore", "-q", "--", denyfile.name]).returncode != 0:
                raise ValueError("The local denylist must be git-ignored and untracked")
            denylist = [line.strip().casefold() for line in denyfile.read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith("#")]
        findings = set()
        scope = (scan_range(args.revision_range, denylist, findings) if args.revision_range is not None
                 else scan_working_tree(root, denylist, findings))
        if findings:
            for label, line, rule in sorted(findings):
                if (any(term in label.casefold() for term in denylist)
                        or HOME_PATH.search(label)
                        or any(not allowed_email(match.group()) for match in EMAIL.finditer(label))):
                    label = "filename withheld"
                print(f"{label!r}:{line}: {rule}", file=sys.stderr)
            print(f"Public safety: FAIL ({len(findings)} findings; matched values withheld)", file=sys.stderr)
            return 1
        print(f"Public safety: PASS — {scope}; {len(denylist)} local denylist terms")
        return 0
    except (OSError, ValueError, IndexError, zlib.error, subprocess.CalledProcessError):
        print("Public safety: ERROR — could not complete scan; check repository, range and local files", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
