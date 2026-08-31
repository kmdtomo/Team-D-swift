#!/usr/bin/env bash
# Fast, source-only gates that run before any compilation in TeamD iOS CI.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

bash -n \
  scripts/ci_source_gates.sh \
  scripts/ci_fixture.sh \
  scripts/ci_live_smoke.sh \
  scripts/lint_t01_01.sh \
  scripts/docs_smoke_fixture.sh

python3 scripts/lint_t19_01_ci.py
python3 scripts/test_lint_t19_01_ci.py
./scripts/lint_t01_01.sh
python3 scripts/lint_t01_02.py
python3 scripts/test_t02_03_docs.py
python3 scripts/lint_t03_02.py
python3 scripts/test_lint_t03_02.py
python3 scripts/verify_t03_03.py
python3 -m unittest scripts/test_verify_t03_03.py
python3 scripts/t11_01_measurement_corpus/lint_corpus.py
python3 -m unittest scripts/t11_01_measurement_corpus/test_lint_corpus.py
python3 scripts/lint_t19_03_inventory.py
python3 scripts/test_lint_t19_03_inventory.py
python3 scripts/test_t19_01_failure_gates.py
python3 scripts/lint_package_graph.py
python3 scripts/ci_secret_scan.py --tracked

empty_tree="$(git hash-object -t tree /dev/null)"
git diff --check "$empty_tree" HEAD

echo "T19-01 source gates passed."
