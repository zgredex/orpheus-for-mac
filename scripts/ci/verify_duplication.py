#!/usr/bin/env python3
"""Reject repeated Swift implementation blocks across production and tests."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path
import re
import sys


MINIMUM_BLOCK_LINES = 8
ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_ROOTS = (
    ROOT / "OrpheusNative",
    ROOT / "NativeQobuzCore" / "Sources" / "NativeQobuzCore",
)
SOURCE_ROOTS = PRODUCTION_ROOTS + (
    ROOT / "OrpheusNativeTests",
    ROOT / "NativeQobuzCore" / "Tests",
)


@dataclass(frozen=True)
class SourceLine:
    number: int
    text: str


@dataclass(frozen=True)
class Clone:
    left: Path
    left_line: int
    right: Path
    right_line: int
    length: int

    @property
    def key(self) -> tuple[str, int, str, int, int]:
        return (
            str(self.left.relative_to(ROOT)),
            self.left_line,
            str(self.right.relative_to(ROOT)),
            self.right_line,
            self.length,
        )


def swift_files() -> list[Path]:
    return sorted({path for root in SOURCE_ROOTS for path in root.rglob("*.swift")})


def substantive_lines(path: Path, *, normalize_literals: bool = False) -> list[SourceLine]:
    result: list[SourceLine] = []
    inside_block_comment = False
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if inside_block_comment:
            if "*/" not in line:
                continue
            line = line.split("*/", 1)[1].strip()
            inside_block_comment = False
        if line.startswith("/*"):
            if "*/" in line:
                line = line.split("*/", 1)[1].strip()
            else:
                inside_block_comment = True
                continue
        line = re.sub(r"//.*$", "", line).strip()
        if not line or line.startswith("import ") or re.fullmatch(r"[{}()]+", line):
            continue
        if normalize_literals:
            line = re.sub(r'"(?:\\.|[^"\\])*"', '"<string>"', line)
            line = re.sub(r"\b\d+(?:\.\d+)?\b", "<number>", line)
        result.append(SourceLine(number, re.sub(r"\s+", " ", line)))
    return result


def find_clones(files: list[Path], source: dict[Path, list[SourceLine]]) -> list[Clone]:
    text = {path: [line.text for line in source[path]] for path in files}
    windows: dict[tuple[str, ...], list[tuple[Path, int]]] = defaultdict(list)
    for path in files:
        for start in range(len(text[path]) - MINIMUM_BLOCK_LINES + 1):
            window = tuple(text[path][start : start + MINIMUM_BLOCK_LINES])
            windows[window].append((path, start))

    clones: dict[tuple[Path, int, Path, int], Clone] = {}
    for locations in windows.values():
        for (left_path, left), (right_path, right) in combinations(locations, 2):
            if left_path == right_path and abs(right - left) < MINIMUM_BLOCK_LINES:
                continue
            if (str(left_path), left) > (str(right_path), right):
                left_path, right_path = right_path, left_path
                left, right = right, left
            if (
                left > 0
                and right > 0
                and text[left_path][left - 1] == text[right_path][right - 1]
            ):
                continue

            length = MINIMUM_BLOCK_LINES
            while (
                left + length < len(text[left_path])
                and right + length < len(text[right_path])
                and text[left_path][left + length] == text[right_path][right + length]
                and (left_path != right_path or left + length < right)
            ):
                length += 1

            key = (left_path, left, right_path, right)
            clones[key] = Clone(
                left_path,
                source[left_path][left].number,
                right_path,
                source[right_path][right].number,
                length,
            )
    return list(clones.values())


def main() -> int:
    files = swift_files()
    source = {path: substantive_lines(path) for path in files}
    clones = find_clones(files, source)

    production_files = sorted({path for root in PRODUCTION_ROOTS for path in root.rglob("*.swift")})
    structural_source = {
        path: substantive_lines(path, normalize_literals=True)
        for path in production_files
    }
    exact_locations = {
        (clone.left, clone.left_line, clone.right, clone.right_line)
        for clone in clones
    }
    clones.extend(
        clone
        for clone in find_clones(production_files, structural_source)
        if (clone.left, clone.left_line, clone.right, clone.right_line) not in exact_locations
    )
    clones.sort(key=lambda clone: clone.key)

    if not clones:
        print(f"Duplication guard passed across {len(files)} Swift files.")
        return 0

    print(
        f"Duplication guard found {len(clones)} repeated implementation blocks "
        f"of at least {MINIMUM_BLOCK_LINES} substantive lines:",
        file=sys.stderr,
    )
    for clone in clones:
        left = clone.left.relative_to(ROOT)
        right = clone.right.relative_to(ROOT)
        print(
            f"  {left}:{clone.left_line} == {right}:{clone.right_line} "
            f"({clone.length} lines)",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
