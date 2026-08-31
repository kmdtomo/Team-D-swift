#!/usr/bin/env python3
"""Reject every Xcode warning except the known Xcode 26.2 AppIntents tool defect."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ALLOWED_WARNING = re.compile(
    r"^.*appintentsmetadataprocessor\[\d+:\d+\] warning: "
    r"Metadata extraction skipped\. No AppIntents\.framework dependency found\.$"
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_xcode_warnings.py <xcodebuild-log>", file=sys.stderr)
        return 2
    warnings = [
        line
        for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
        if "warning:" in line.casefold()
    ]
    unexpected = [line for line in warnings if not ALLOWED_WARNING.fullmatch(line)]
    if unexpected:
        print("unexpected Xcode warnings:", *unexpected, sep="\n", file=sys.stderr)
        return 1
    print(f"Xcode warnings checked: {len(warnings)} known AppIntents tool warnings allowlisted; 0 unexpected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
