#!/usr/bin/env bash
# Run the exact fixture-only command sequence documented in docs/development/fixture-baseline.md.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
started_at="$(date +%s)"
status_before="$(git status --porcelain=v1 --untracked-files=all)"

xcode_version="$(xcodebuild -version)"
if [[ "$xcode_version" != $'Xcode 26.2\nBuild version 17C52' ]]; then
  echo "Xcode 26.2 (17C52) is required for this documented fixture baseline." >&2
  printf '%s\n' "$xcode_version" >&2
  exit 1
fi

select_existing_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json
import os
import sys

devices = json.load(sys.stdin)["devices"]
requested = os.environ.get("TEAM_D_SIMULATOR_UDID")
requested_name = os.environ.get("TEAM_D_SIMULATOR_NAME")
requested_runtime = os.environ.get("TEAM_D_SIMULATOR_RUNTIME")
candidates = [
    dict(device, runtime=runtime)
    for runtime, runtime_devices in devices.items()
    for device in runtime_devices
    if device.get("isAvailable") and device.get("name", "").startswith("iPhone")
]
if requested_runtime:
    candidates = [device for device in candidates if device["runtime"] == requested_runtime]
if requested_name:
    candidates = [device for device in candidates if device["name"] == requested_name]
if requested:
    match = next((device for device in candidates if device["udid"] == requested), None)
    if match is None:
        raise SystemExit("TEAM_D_SIMULATOR_UDID must identify an available iPhone Simulator")
    print(match["udid"])
    raise SystemExit(0)
booted = next((device for device in candidates if device.get("state") == "Booted"), None)
if booted:
    print(booted["udid"])
    raise SystemExit(0)
if candidates:
    print(candidates[0]["udid"])
'
}

select_runtime_for_temporary_simulator() {
  xcrun simctl list runtimes available -j | python3 -c '
import json
import os
import sys

runtimes = json.load(sys.stdin)["runtimes"]
requested = os.environ.get("TEAM_D_SIMULATOR_RUNTIME")
if requested:
    if not any(runtime["identifier"] == requested and runtime.get("isAvailable") for runtime in runtimes):
        raise SystemExit("TEAM_D_SIMULATOR_RUNTIME must identify an available iOS Simulator runtime")
    print(requested)
    raise SystemExit(0)
candidates = [runtime["identifier"] for runtime in runtimes if runtime.get("isAvailable") and ".iOS-" in runtime["identifier"]]
if not candidates:
    raise SystemExit("No available iOS Simulator runtime found; install one in Xcode.")
print(sorted(candidates)[-1])
'
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/teamd-fixture-docs-smoke.XXXXXX")"
simulator_udid=""
created_simulator=0
simulator_was_booted=0
cleanup() {
  cleanup_status=0
  rm -rf "$temporary_root"
  if [[ "$created_simulator" -eq 1 && -n "$simulator_udid" ]]; then
    xcrun simctl delete "$simulator_udid" || cleanup_status=1
  elif [[ "$simulator_was_booted" -eq 0 && -n "$simulator_udid" ]]; then
    xcrun simctl shutdown "$simulator_udid" || cleanup_status=1
  fi
  finished_at="$(date +%s)"
  elapsed_seconds=$((finished_at - started_at))
  status_after="$(git status --porcelain=v1 --untracked-files=all)"
  echo "Fixture docs smoke elapsed seconds: $elapsed_seconds"
  if [[ "$status_before" != "$status_after" ]]; then
    echo "Repository status changed during fixture docs smoke; generated artifacts must not dirty the worktree." >&2
    cleanup_status=1
  else
    echo "Repository status unchanged before and after fixture docs smoke."
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    exit "$cleanup_status"
  fi
}
trap cleanup EXIT

simulator_udid="$(select_existing_simulator)"
if [[ -z "$simulator_udid" ]]; then
  temporary_runtime="$(select_runtime_for_temporary_simulator)"
  temporary_name="${TEAM_D_SIMULATOR_NAME:-iPhone 17 Pro}"
  simulator_udid="$(xcrun simctl create 'TeamD Fixture Docs Smoke' "$temporary_name" "$temporary_runtime")"
  created_simulator=1
fi

if [[ "$(xcrun simctl list devices -j | python3 -c '
import json
import sys

requested = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["udid"] == requested:
            print("1" if device.get("state") == "Booted" else "0")
            raise SystemExit(0)
raise SystemExit("Selected Simulator is no longer available")
' "$simulator_udid")" == "1" ]]; then
  simulator_was_booted=1
fi

xcrun simctl boot "$simulator_udid" 2>/dev/null || true
xcrun simctl bootstatus "$simulator_udid" -b

simulator_description="$(xcrun simctl list devices -j | python3 -c '
import json
import sys

requested = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["udid"] == requested:
            print("{} ({})".format(device["name"], runtime))
            raise SystemExit(0)
raise SystemExit("Selected Simulator is no longer available")
' "$simulator_udid")"
echo "Selected fixture Simulator: $simulator_description [$simulator_udid]"
echo "Fixture docs smoke started at epoch seconds: $started_at"
host_architecture="$(uname -m)"
case "$host_architecture" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported host architecture for the fixture Simulator: $host_architecture" >&2
    exit 1
    ;;
esac

swift build --package-path Packages --scratch-path "$temporary_root/swiftpm"

xcodebuild test \
  -workspace TeamD.xcworkspace \
  -scheme TeamD \
  -configuration Debug-Fixture \
  -destination "platform=iOS Simulator,id=$simulator_udid,arch=$host_architecture" \
  -derivedDataPath "$temporary_root/derived-data" \
  -only-testing:TeamDUITests/TeamDUITests/testColdLaunchEntersCameraFlowWithoutHomeOrTabs \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$temporary_root/xcodebuild.log"

python3 scripts/check_xcode_warnings.py "$temporary_root/xcodebuild.log"
