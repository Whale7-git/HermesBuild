#!/usr/bin/env python3
"""Fail on a chained Swift view modifier applied to a control-flow statement.

Linux CI cannot type-check SwiftUI. This is a deliberately narrow text guard,
not a substitute for an iOS SDK-backed Swift compiler invocation.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CONTROL = re.compile(r'(?m)^\s*(?:if|for|switch|guard|while|else)\b')
MODIFIER = re.compile(r'^(?P<indent>[ \t]*)\.[A-Za-z_][A-Za-z_0-9]*\b')


def mask_non_code(source: str) -> str:
    """Keep braces/newlines in Swift code, blanking comments and string literals.

    Handles nested block comments, normal and raw string delimiters, and triple
    quotes. This is intentionally lexical and not a full Swift parser.
    """
    out = list(source)
    i, end = 0, len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if source[k] != '\n':
                out[k] = ' '

    while i < end:
        if source.startswith('//', i):
            stop = source.find('\n', i)
            if stop == -1:
                stop = end
            blank(i, stop)
            i = stop
        elif source.startswith('/*', i):
            start, depth = i, 1
            i += 2
            while i < end and depth:
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            blank(start, i)
        elif source[i] == '"' or source[i] == '#':
            start, hashes = i, 0
            if source[i] == '#':
                while i + hashes < end and source[i + hashes] == '#':
                    hashes += 1
                if i + hashes >= end or source[i + hashes] != '"':
                    i += 1
                    continue
            quote_start = i + hashes
            triple = source.startswith('"""', quote_start)
            opener = 3 if triple else 1
            closer = '"' * opener + '#' * hashes
            i = quote_start + opener
            while i < end:
                if source.startswith(closer, i):
                    i += len(closer)
                    break
                # Swift raw strings escape with backslash + their hash prefix.
                if source[i] == '\\' and source.startswith('#' * hashes, i + 1):
                    i += 2 + hashes
                else:
                    i += 1
            blank(start, i)
        else:
            i += 1
    return ''.join(out)


def offenses(source: str) -> list[tuple[int, str]]:
    lines = source.splitlines()
    clean = mask_non_code(source)
    # Track the kind of block matched by each closing brace. A Group/HStack/
    # VStack brace is not a control-flow brace, and remains legal.
    stack: list[bool] = []
    close_kind: dict[int, bool] = {}
    head = 0
    for line_no, line in enumerate(clean.splitlines(keepends=True), 1):
        for col, char in enumerate(line):
            if char == '{':
                prefix = clean[:head + col]
                # Restrict to the current statement; previous braces and
                # semicolons separate ViewBuilders from nested if/else blocks.
                prefix = re.split(r'[{};]', prefix)[-1]
                stack.append(bool(CONTROL.search(prefix)))
            elif char == '}':
                close_kind[line_no] = stack.pop() if stack else False
        head += len(line)

    bad: list[tuple[int, str]] = []
    for i, line in enumerate(lines[1:], 1):
        mod = MODIFIER.match(line)
        if not mod:
            continue
        prev = lines[i - 1]
        if not re.match(r'^([ \t]*)}\s*(?://.*)?$', prev):
            continue
        brace_indent = len(prev) - len(prev.lstrip(' \t'))
        modifier_indent = len(mod.group('indent'))
        if modifier_indent > brace_indent and close_kind.get(i, False):
            bad.append((i + 1, line.strip()))
    return bad


# Known build216 findings are intentionally NOT changed by the test-only PR.
# An explicit call-site allowlist keeps prior behavior, while a newly added
# unguarded animation fails. Each entry is an issue for a separate product PR.
REVIEWED_LEGACY_ANIMATIONS = {
    ("ChatMessageReader.swift", "withAnimation(.easeOut(duration: 0.18))"),
    ("RootView.swift", "withAnimation(.easeOut(duration: 0.24), completionCriteria: .logicallyComplete)"),
    ("SessionDrawer.swift", "withAnimation(.easeOut(duration: 0.2))"),
    ("SessionDrawer.swift", "withAnimation(.easeIn(duration: 0.2))"),
}


def ui_interaction_offenses(source: str, filename: str = "") -> list[tuple[int, str]]:
    """Conservative high-confidence UI diagnostics; never guess a view's frame.

    Hit regions from composed overlays/padding and inferred hosting height
    require XCUITest. Only an actually bare icon-only label is flagged here.
    """
    clean = mask_non_code(source)
    results: list[tuple[int, str]] = []

    # Button { action } label: { Image(systemName: "...") } is visibly
    # under-sized without sizing or padding either inside or immediately
    # outside the label. Do not flag composite labels, custom ButtonStyles,
    # or views whose real hit frame cannot be inferred lexically.
    for found in re.finditer(r'}\s*label:\s*{', clean):
        prefix = clean[max(0, found.start() - 400):found.start()]
        if not re.search(r'\bButton\s*(?:\([^{}]*\))?\s*{', prefix):
            continue
        start = found.end() - 1
        depth, end = 0, start
        for end in range(start, len(clean)):
            depth += (clean[end] == '{') - (clean[end] == '}')
            if depth == 0:
                break
        if depth:
            continue
        inside = clean[start + 1:end].strip()
        # A single SF Symbol, optionally styled but never sized, is the
        # only shape whose hit area we can confidently reject from source.
        if not re.match(r'^Image\s*\(\s*systemName\s*:', inside):
            continue
        if inside.count('Image(') != 1 or any(t in inside for t in (
            'HStack', 'VStack', 'ZStack', 'Group', 'Text(', 'if ', 'Button(')):
            continue
        trailing = clean[end + 1:end + 260].split('\n\n', 1)[0]
        sizing = inside + trailing
        if any(t in sizing for t in ('.frame(', '.padding(', '.contentShape(')):
            continue
        # Avoid declaring an involved label when there are further nested
        # closures; audit these visually through XCUITest instead.
        if '{' in inside or '}' in inside:
            continue
        results.append((source.count('\n', 0, found.start()) + 1,
                        "bare SF Symbol Button label lacks a declared hit region"))

    # File-wide presence of accessibilityReduceMotion is NOT sufficient:
    # detect each unguarded literal animation constructor separately.
    for found in re.finditer(r'\bwithAnimation\s*\(\s*\.[A-Za-z]\w*', clean):
        line = source.count('\n', 0, found.start()) + 1
        snippet = source[found.start():].split('\n', 1)[0].strip()
        if any(snippet.startswith(signature) for file, signature in
               REVIEWED_LEGACY_ANIMATIONS if file == filename):
            continue
        results.append((line, "withAnimation uses an unguarded literal animation; use reduceMotion ? nil : ..."))

    # A UIScrollView-hosted SwiftUI view with neither explicit height nor
    # manual contentSize is a *risk*, not proof that scrolling is broken.
    # Its existing reader instance is documented as a baseline finding;
    # UI tests must measure actual contentOffset before a product fix.
    if (filename != "ChatMessageReader.swift"
            and 'UIHostingController' in clean and 'scrollView.addSubview(host.view)' in clean
            and 'contentLayoutGuide' in clean
            and 'heightAnchor.constraint' not in clean
            and 'scrollView.contentSize' not in clean):
        idx = clean.index('scrollView.addSubview(host.view)')
        results.append((source.count('\n', 0, idx) + 1,
                        "hosted scroll content has no explicit size source; verify geometry"))

    return results


def check(paths: list[Path]) -> int:
    issues = 0
    for path in paths:
        source = path.read_text(encoding='utf-8')
        for line, modifier in offenses(source):
            print(f'{path}:{line}: control-flow brace followed by {modifier}; '
                  'wrap branches in Group { ... } before applying a modifier',
                  file=sys.stderr)
            issues += 1
        for line, reason in ui_interaction_offenses(source, path.name):
            print(f'{path}:{line}: {reason}', file=sys.stderr)
            issues += 1
    if issues:
        print(f'SWIFTUI_MODIFIER_GATE_FAIL: {issues} unsafe modifier(s)', file=sys.stderr)
        return 1
    print(f'SCAN_PASS swiftui_modifier_gate ({len(paths)} Swift source files)')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('paths', nargs='*', type=Path,
                    help='Swift files, directory names or shell globs; default: Sources/HermesShell')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    # Github Actions invokes this with no args; local users can pass shell
    # globs, directories, or literal files without getting a vacuous pass.
    paths = []
    if args.paths:
        import glob
        for candidate in args.paths:
            text = str(candidate)
            if any(ch in text for ch in '*?['):
                paths.extend(Path(item) for item in glob.glob(text, recursive=True))
            elif candidate.is_dir():
                paths.extend(candidate.rglob('*.swift'))
            else:
                paths.append(candidate)
    else:
        paths = list((root / 'Sources/HermesShell').rglob('*.swift'))
    paths = sorted({p for p in paths if p.is_file() and p.suffix == '.swift'})
    if not paths:
        ap.error('no Swift files found (refusing a vacuous pass)')
    return check(paths)


if __name__ == '__main__':
    raise SystemExit(main())
