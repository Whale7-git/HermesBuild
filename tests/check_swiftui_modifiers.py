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


def check(paths: list[Path]) -> int:
    issues = 0
    for path in paths:
        for line, modifier in offenses(path.read_text(encoding='utf-8')):
            print(f'{path}:{line}: control-flow brace followed by {modifier}; '
                  'wrap branches in Group { ... } before applying a modifier',
                  file=sys.stderr)
            issues += 1
    if issues:
        print(f'SWIFTUI_MODIFIER_GATE_FAIL: {issues} unsafe modifier(s)', file=sys.stderr)
        return 1
    print(f'swiftui_modifier_gate: pass ({len(paths)} Swift source files)')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('paths', nargs='*', type=Path,
                    help='Swift source files; default: Sources/HermesShell')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = args.paths or sorted((root / 'Sources/HermesShell').rglob('*.swift'))
    if not paths:
        ap.error('no Swift files found (refusing a vacuous pass)')
    return check(paths)


if __name__ == '__main__':
    raise SystemExit(main())
