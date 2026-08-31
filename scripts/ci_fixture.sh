#!/usr/bin/env bash
# Run the complete Debug-Fixture CI suite without shared project caches.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

expected_xcode=$'Xcode 26.2\nBuild version 17C52'
actual_xcode="$(xcodebuild -version)"
if [[ "$actual_xcode" != "$expected_xcode" ]]; then
  echo "T19-01 requires Xcode 26.2 (17C52)." >&2
  printf '%s\n' "$actual_xcode" >&2
  exit 1
fi

scratch_root="${TEAM_D_CI_SCRATCH:-}"
scratch_is_temporary=0
if [[ -z "$scratch_root" ]]; then
  scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/teamd-ios-ci-scratch.XXXXXX")"
  scratch_is_temporary=1
fi
artifact_root="${TEAM_D_CI_ARTIFACTS:-}"
if [[ -z "$artifact_root" ]]; then
  artifact_root="$(mktemp -d "${TMPDIR:-/tmp}/teamd-ios-ci-artifacts.XXXXXX")"
fi

case "$scratch_root" in
  /*) ;;
  *) echo "TEAM_D_CI_SCRATCH must be an absolute path." >&2; exit 1 ;;
esac
case "$artifact_root" in
  /*) ;;
  *) echo "TEAM_D_CI_ARTIFACTS must be an absolute path." >&2; exit 1 ;;
esac
case "$scratch_root" in
  "$repository_root"|"$repository_root"/*) echo "CI scratch must be outside the repository." >&2; exit 1 ;;
esac
case "$artifact_root" in
  "$repository_root"|"$repository_root"/*) echo "CI artifacts must be outside the repository." >&2; exit 1 ;;
esac
if [[ "$scratch_root" == "/" || "$artifact_root" == "/" || "$scratch_root" == "$artifact_root" ]]; then
  echo "CI scratch and artifacts must be distinct, scoped directories." >&2
  exit 1
fi

mkdir -p "$scratch_root" "$artifact_root"
if [[ -n "$(find "$scratch_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "CI scratch must start empty; shared/restored project caches are forbidden." >&2
  exit 1
fi
if [[ -n "$(find "$artifact_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "CI artifact directory must start empty." >&2
  exit 1
fi
status_before="$(git status --porcelain=v1 --untracked-files=all)"
simulator_udid=""

cleanup() {
  command_status=$?
  trap - EXIT
  if [[ -n "$simulator_udid" ]]; then
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
  fi
  if [[ "$scratch_is_temporary" -eq 1 ]]; then
    rm -rf -- "$scratch_root"
  fi
  status_after="$(git status --porcelain=v1 --untracked-files=all)"
  if [[ "$status_before" != "$status_after" ]]; then
    echo "CI fixture suite changed the repository worktree." >&2
    command_status=1
  fi
  if [[ "$command_status" -eq 0 ]]; then
    echo "T19-01 fixture suite passed. Artifacts: $artifact_root"
  fi
  exit "$command_status"
}
trap cleanup EXIT

device_type="${TEAM_D_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
device_name="${TEAM_D_SIMULATOR_NAME:-iPhone 17 Pro}"
runtime="${TEAM_D_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-2}"

xcrun simctl list devicetypes -j | python3 -c '
import json, sys
requested = sys.argv[1]
expected_name = sys.argv[2]
if not any(item.get("identifier") == requested and item.get("name") == expected_name for item in json.load(sys.stdin)["devicetypes"]):
    raise SystemExit("required iPhone 17 Pro Simulator device type is unavailable")
' "$device_type" "$device_name"
xcrun simctl list runtimes available -j | python3 -c '
import json, sys
requested = sys.argv[1]
if not any(item.get("identifier") == requested and item.get("isAvailable") for item in json.load(sys.stdin)["runtimes"]):
    raise SystemExit("required iOS 26.2 Simulator runtime is unavailable")
' "$runtime"

simulator_udid="$(xcrun simctl create "TeamD T19-01 CI ${GITHUB_RUN_ID:-local}" "$device_type" "$runtime")"
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b

host_architecture="$(uname -m)"
case "$host_architecture" in
  arm64|x86_64) ;;
  *) echo "Unsupported CI host architecture: $host_architecture" >&2; exit 1 ;;
esac
destination="platform=iOS Simulator,id=$simulator_udid,arch=$host_architecture"
derived_data="$scratch_root/derived-data"
source_packages="$scratch_root/source-packages"
swiftpm_scratch="$scratch_root/swiftpm"
export CLANG_MODULE_CACHE_PATH="$scratch_root/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_root/swiftpm-module-cache"

swift package \
  --package-path Packages \
  --scratch-path "$swiftpm_scratch" \
  resolve 2>&1 | tee "$artifact_root/swift-package-resolve.log"

xcodebuild -resolvePackageDependencies \
  -workspace TeamD.xcworkspace \
  -scheme TeamD \
  -configuration Debug-Fixture \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  2>&1 | tee "$artifact_root/xcode-resolve.log"

swift build \
  --package-path Packages \
  --scratch-path "$swiftpm_scratch" \
  2>&1 | tee "$artifact_root/swift-build.log"

swift test \
  --package-path Packages \
  --scratch-path "$swiftpm_scratch" \
  2>&1 | tee "$artifact_root/swift-test.log"

xcodebuild build-for-testing \
  -workspace TeamD.xcworkspace \
  -scheme TeamD \
  -configuration Debug-Fixture \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$artifact_root/build-for-testing.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$artifact_root/build-for-testing.log"

fixture_product="$derived_data/Build/Products/Debug-Fixture-iphonesimulator/TeamD.app"
python3 scripts/verify_t03_03.py --product "$fixture_product" --expected-mode fixture

xcodebuild test-without-building \
  -workspace TeamD.xcworkspace \
  -scheme TeamD \
  -configuration Debug-Fixture \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$artifact_root/fixture-tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$artifact_root/fixture-tests.log"

python3 scripts/check_xcode_warnings.py "$artifact_root/xcode-resolve.log"
python3 scripts/check_xcode_warnings.py "$artifact_root/build-for-testing.log"
python3 scripts/check_xcode_warnings.py "$artifact_root/fixture-tests.log"
python3 scripts/ci_secret_scan.py --path "$fixture_product" --path "$artifact_root"
