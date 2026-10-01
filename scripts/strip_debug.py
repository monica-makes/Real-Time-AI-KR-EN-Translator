#!/usr/bin/env python3
"""Strip the iOS app's debug options and demos, leaving exactly what a Release build compiles.

`main` is the shippable app: `debug-prototyping` with every `#if DEBUG` block removed (its `#else`
arm kept) and the files that were debug-only deleted. scripts/sync-main.sh runs this on a clean
checkout of `debug-prototyping` and commits the result to `main`, so the branches can't drift.

    python3 scripts/strip_debug.py <checkout root>

To keep the strip clean on debug-prototyping:
  - every debug option, panel, harness and demo goes inside `#if DEBUG`, call sites too (a
    modifier can sit on its own line between `#if DEBUG` and `#endif`)
  - a comment that introduces a debug-only block sits right above its `#if DEBUG` (it goes with
    it) or inside it
  - a file that is all debug is wrapped in `#if DEBUG` and lives in Views/Components (a synced
    folder, so deleting it needs no project change); other debug-only files go in DEBUG_ONLY_FILES
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP = Path("KorEngTranslator")
# Xcode picks up whatever is in this folder, so files can be removed without touching the project
SYNCED = APP / "KorEngTranslator/Views/Components"

DEBUG_ONLY_FILES = [
    SYNCED / "Bubbles/OrbFlowField.metal",  # the reel's Flow orb shader; Metal can't see DEBUG
]

DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


class StripError(Exception):
    pass


def directive(line: str) -> tuple[str, str] | None:
    m = DIRECTIVE.match(line)
    return (m.group(1), m.group(2).split("//")[0].strip()) if m else None


def debug_gates_with_else(lines: list[str]) -> set[int]:
    """Indexes of the `#if DEBUG` / `#if !DEBUG` lines whose block has an `#else`."""
    found: set[int] = set()
    stack: list[int] = []
    for i, line in enumerate(lines):
        d = directive(line)
        if not d:
            continue
        if d[0] == "if":
            stack.append(i)
        elif d[0] == "else" and stack:
            found.add(stack[-1])
        elif d[0] == "endif" and stack:
            stack.pop()
    return found


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")


def strip_swift(text: str, name: str) -> str:
    """Drops `#if DEBUG` arms and keeps `#else` arms; leaves every other `#if` alone."""
    lines = text.splitlines(keepends=True)
    has_else = debug_gates_with_else(lines)
    out: list[str] = []
    # One frame per open #if: (is_debug_gate, keeping_this_arm)
    stack: list[tuple[bool, bool]] = []
    dropped = False  # lines dropped since the last kept one

    def keeping() -> bool:
        return all(keep for _, keep in stack)

    def drop_intro_comment() -> None:
        """The comment right above a debug-only block goes with it (a `// MARK:` may sit a blank
        line above)."""
        end = len(out)
        if end > 1 and not out[end - 1].strip() and out[end - 2].lstrip().startswith("// MARK:"):
            end -= 1
        start = end
        while start and is_comment(out[start - 1]):
            start -= 1
        if start < end:
            del out[start:]

    for number, line in enumerate(lines, 1):
        d = directive(line)
        if d:
            kind, condition = d
            if kind == "if":
                if condition in ("DEBUG", "!DEBUG"):
                    if keeping() and condition == "DEBUG" and number - 1 not in has_else:
                        drop_intro_comment()
                    stack.append((True, condition == "!DEBUG"))
                    dropped = True
                    continue
                if re.search(r"\bDEBUG\b", condition):
                    raise StripError(f"{name}:{number}: compound DEBUG condition `{condition}`")
                stack.append((False, True))
            elif not stack:
                raise StripError(f"{name}:{number}: #{kind} without #if")
            elif stack[-1][0]:
                if kind == "elseif":
                    raise StripError(f"{name}:{number}: #elseif in a DEBUG block")
                if kind == "else":
                    stack[-1] = (True, not stack[-1][1])
                else:
                    stack.pop()
                dropped = True
                continue
            elif kind == "endif":
                stack.pop()
        if not keeping():
            dropped = True
            continue
        if dropped and out:
            # Don't leave a double blank line, a blank line after an opening brace, or one
            # before a closing bracket
            if not line.strip() and (not out[-1].strip() or out[-1].rstrip().endswith("{")):
                continue
            if line.lstrip().startswith(("}", ")")) and not out[-1].strip():
                out.pop()
        out.append(line)
        dropped = False
    if stack:
        raise StripError(f"{name}: unterminated #if")
    while out and not out[-1].strip():
        out.pop()
    return "".join(out)


def is_empty_swift(text: str) -> bool:
    code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for line in code.splitlines():
        line = line.split("//")[0].strip()
        if line and not line.startswith("import "):
            return False
    return True


def main(root: Path) -> None:
    removed: list[Path] = []
    for rel in DEBUG_ONLY_FILES:
        if (root / rel).exists():
            (root / rel).unlink()
            removed.append(rel)

    stripped = 0
    for path in sorted((root / APP).rglob("*.swift")):
        rel = path.relative_to(root)
        text = path.read_text()
        if not re.search(r"^\s*#if !?DEBUG\b", text, flags=re.M):
            continue
        result = strip_swift(text, str(rel))
        if is_empty_swift(result):
            if SYNCED not in rel.parents:
                raise StripError(f"{rel} is all debug but outside {SYNCED}; the project still lists it")
            path.unlink()
            removed.append(rel)
        else:
            path.write_text(result)
            stripped += 1

    for folder in sorted({p.parent for p in removed}, key=lambda p: -len(p.parts)):
        if (root / folder).is_dir() and not any((root / folder).iterdir()):
            (root / folder).rmdir()

    for rel in removed:
        print(f"removed  {rel}")
    print(f"stripped {stripped} files")

    leftovers = [
        f"{p.relative_to(root)}:{n}: {line.strip()}"
        for p in sorted((root / APP).rglob("*.swift"))
        for n, line in enumerate(p.read_text().splitlines(), 1)
        if re.search(r"\bDEBUG\b", line)
    ]
    if leftovers:
        raise StripError("DEBUG still mentioned after the strip:\n  " + "\n  ".join(leftovers))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    try:
        main(Path(sys.argv[1]).resolve())
    except StripError as error:
        sys.exit(f"strip_debug: {error}")
