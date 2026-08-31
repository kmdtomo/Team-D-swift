#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
requirements="$repo_root/requirements.md"
tasks="$repo_root/task.md"
expected_sha="44065d41e8906d34e5d8e11d7cd4cc14b25d17f2"
source_url="https://github.com/neko-jpg/Team-D/tree/$expected_sha"

fail() {
  printf 'T01-01 lint: %s\n' "$1" >&2
  exit 1
}

for document in "$requirements" "$tasks"; do
  grep -Fq "$expected_sha" "$document" || fail "missing snapshot SHA in ${document#$repo_root/}"
  grep -Fq "$source_url" "$document" || fail "missing immutable snapshot URL in ${document#$repo_root/}"
done

[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'snapshot SHA must be 40 lowercase hexadecimal characters'

while IFS= read -r pinned_sha; do
  [[ "$pinned_sha" == "$expected_sha" ]] || fail "found a second source snapshot SHA: $pinned_sha"
done < <((grep -hoE 'https://github\.com/neko-jpg/Team-D/(blob|tree)/[0-9a-f]{40}/[^ )`]+' "$requirements" "$tasks" || true) \
  | sed -E 's#https://github\.com/neko-jpg/Team-D/(blob|tree)/([0-9a-f]{40})/.*#\2#' \
  | sort -u)

while IFS= read -r named_pin; do
  [[ "$named_pin" == "neko-jpg/Team-D@$expected_sha" ]] || fail "found a malformed or second named source pin: $named_pin"
done < <((grep -hoE 'neko-jpg/Team-D@[A-Za-z0-9._-]+' "$requirements" "$tasks" || true) | sort -u)

if grep -hE 'https://github\.com/neko-jpg/Team-D/(blob|tree)/main/' "$requirements" "$tasks" >/dev/null; then
  fail 'source blob/tree URLs must not use main'
fi

while IFS= read -r pinned_url; do
  [[ "$pinned_url" == "$source_url" || "$pinned_url" == *"/$expected_sha/"* ]] || fail "pinned source URL does not use the fixed snapshot: $pinned_url"
done < <(grep -hoE 'https://github\.com/neko-jpg/Team-D/(blob|tree)/[^ )`]+' "$requirements" "$tasks" | sort -u)

grep -Fq '現行参照元の3slot実装は正本ではない' "$tasks" || fail '3slot non-canonical boundary is missing'
grep -Fq 'fixtureはXcode/Simulatorで決定的に完走する開発・検証モード' "$tasks" || fail 'fixture/live boundary is missing'
grep -Fq '| Guidance sequence |' "$tasks" || fail 'sequence contract difference is missing'
grep -Fq '| Agent Guidance push |' "$tasks" || fail 'Guidance push blocker is missing'
grep -Fq '| 4つのHTTP endpoint |' "$tasks" || fail 'HTTP endpoint blocker is missing'
grep -Fq '| fixture binary |' "$tasks" || fail 'fixture binary blocker is missing'
grep -Fq '| AC-DEVICE-001 evidence |' "$tasks" || fail 'AC-DEVICE evidence gap is missing'
grep -Fq '| Swift受け入れID | 実装・検証タスク | 参照元根拠（source → Swift AC） |' "$tasks" || fail 'source-to-AC traceability header is missing'

if ! awk -F '|' '/^\| AC-[A-Z]+-[0-9]{3} \|/ { rows++; if (NF != 5 || $4 !~ /SRC-[RABGD]/) bad = 1 } END { exit (rows > 0 && !bad) ? 0 : 1 }' "$tasks"; then
  fail 'each traceability row must contain a source evidence label'
fi

if ! awk -F '|' '
  BEGIN {
    required["Guidance sequence"] = 1
    required["Agent Guidance push"] = 1
    required["4つのHTTP endpoint"] = 1
    required["fixture binary"] = 1
    required["AC-DEVICE-001 evidence"] = 1
  }
  /^\|/ {
    name = $2; fact = $3; owner = $4
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", fact)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
    if (name in required) {
      seen[name] = 1
      if (fact == "" || owner == "") bad = 1
    }
  }
  END {
    for (name in required) if (!(name in seen)) bad = 1
    exit bad ? 1 : 0
  }
' "$tasks"; then
  fail 'every named blocker must include non-empty current-state and owner/release columns'
fi

if find "$repo_root" -path "$repo_root/.git" -prune -o -type d -name openspec -print -quit | grep -q .; then
  fail 'openspec directory must not exist in the Swift repository'
fi

acceptance_count=0
while IFS= read -r acceptance_id; do
  acceptance_count=$((acceptance_count + 1))
  requirement_count="$( (grep -oE 'AC-[A-Z]+-[0-9]{3}' "$requirements" || true) | awk -v id="$acceptance_id" '$0 == id { count++ } END { print count + 0 }' )"
  [[ "$requirement_count" == 1 ]] || fail "$acceptance_id must occur exactly once in requirements.md (found $requirement_count)"
  count="$(grep -Ec "^\\| $acceptance_id \\| T[0-9]{2}-[0-9]{2}" "$tasks" || true)"
  [[ "$count" == 1 ]] || fail "$acceptance_id must have exactly one traceability row (found $count)"
done < <(grep -oE 'AC-[A-Z]+-[0-9]{3}' "$requirements" | sort -u)
(( acceptance_count > 0 )) || fail 'no acceptance IDs found in requirements.md'

while IFS= read -r trace_acceptance_id; do
  requirement_count="$( (grep -oE 'AC-[A-Z]+-[0-9]{3}' "$requirements" || true) | awk -v id="$trace_acceptance_id" '$0 == id { count++ } END { print count + 0 }' )"
  [[ "$requirement_count" == 1 ]] || fail "$trace_acceptance_id is trace-only or duplicated in requirements.md"
done < <(grep -oE '^\| AC-[A-Z]+-[0-9]{3} \|' "$tasks" | grep -oE 'AC-[A-Z]+-[0-9]{3}' | sort -u)

while IFS= read -r task_id; do
  grep -Fq "**$task_id " "$tasks" || fail "traceability references unknown task $task_id"
done < <(sed -n '/| AC-/,/^$/p' "$tasks" | grep -oE 'T[0-9]{2}-[0-9]{2}' | sort -u)

printf 'T01-01 lint passed: %s acceptance IDs mapped; snapshot %s verified.\n' "$acceptance_count" "$expected_sha"
