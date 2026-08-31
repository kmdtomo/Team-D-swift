#!/usr/bin/env python3
"""Verify the explicit local Swift package graph remains a directed acyclic graph."""
from __future__ import annotations

import re
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1] / "Packages" / "Package.swift"
TARGET = re.compile(r'\.target\(\s*name:\s*"([^"]+)"(?P<body>.*?)(?=\n\s*\.target\(|\n\s*\]\n\))', re.S)
QUOTED = re.compile(r'"([A-Za-z][A-Za-z0-9]+)"')


def main() -> int:
    source = PACKAGE.read_text(encoding="utf-8")
    graph: dict[str, set[str]] = {}
    for match in TARGET.finditer(source):
        name = match.group(1)
        dependency_section = match.group("body").split("path:", 1)[0]
        graph[name] = set(QUOTED.findall(dependency_section)) - {name}

    if set(graph) != {
        "DomainKit", "ContractKit", "CaptureKit", "APIClient", "LiveKitBridge",
        "MeasurementKit", "CompositionKit", "TestSupport",
    }:
        print("error: Package.swift must declare precisely the eight T02-01 local targets", file=sys.stderr)
        return 1

    active: set[str] = set()
    complete: set[str] = set()

    def visit(node: str) -> None:
        if node in active:
            raise ValueError(f"dependency cycle includes {node}")
        if node in complete:
            return
        active.add(node)
        for dependency in graph[node]:
            if dependency not in graph:
                raise ValueError(f"{node} references unknown local target {dependency}")
            visit(dependency)
        active.remove(node)
        complete.add(node)

    try:
        for target in graph:
            visit(target)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Package target graph is acyclic.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
