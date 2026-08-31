# Fixture Simulator baseline

This is the T02-03 first-run baseline. It reaches one deterministic UI test in
`Debug-Fixture`; it does not start a backend, connect to LiveKit, use a camera,
or require a secret. `fixture` and `live` remain separate modes.

## Supported tools

- macOS with **Xcode 26.2 (17C52)** and an iOS Simulator runtime.
- Xcode's bundled Swift 6.2.3 compiler. The project uses Swift 6 language mode.
- An available iPhone Simulator. The command below prefers an already booted
  iPhone, then selects another matching available iPhone; if none exists, it
  creates and later deletes a temporary one.

Do not install Docker, run a local backend, or add keys, tokens, or `.xcconfig`
files for this fixture baseline.

## Xcode path

1. Clone the repository and open its workspace:

   ```sh
   git clone <repository-url> Team-D-swift
   cd Team-D-swift
   open TeamD.xcworkspace
   ```

2. In Xcode, select the shared `TeamD` scheme, an iPhone Simulator, and the
   `Debug-Fixture` configuration. The shared scheme already uses
   `Debug-Fixture` for Test and Run.
3. Press **Test** (Command-U). Confirm that
   `TeamDUITests.testColdLaunchEntersCameraFlowWithoutHomeOrTabs` passes. It
   launches the deterministic fixture flow and requires neither camera access
   nor an external service.

## Reproducible CLI path

From the repository root, run exactly:

```sh
./scripts/docs_smoke_fixture.sh
```

The script runs these commands in this order: validates the selected Xcode,
selects and boots an available iPhone Simulator, builds local packages, runs
the one `Debug-Fixture` UI test, and checks the Xcode warning policy. It uses a
temporary DerivedData directory and removes it when finished. To use a specific
available Simulator, set non-secret overrides before the command. A UDID is
useful locally; name/runtime pins make a runner configuration reproducible:

```sh
TEAM_D_SIMULATOR_UDID='<simulator-udid>' ./scripts/docs_smoke_fixture.sh
TEAM_D_SIMULATOR_NAME='iPhone 17 Pro' \
TEAM_D_SIMULATOR_RUNTIME='com.apple.CoreSimulator.SimRuntime.iOS-26-2' \
  ./scripts/docs_smoke_fixture.sh
```

The Simulator destination is identified by UDID and uses the current host
architecture (`arm64` or `x86_64`) dynamically, rather than hard-coding an
Apple Silicon-only architecture. The same command therefore works on Apple
Silicon and standard Intel runners.

The expected result is `TEST SUCCEEDED` followed by the warning checker
reporting zero unexpected warnings. The checker permits only the known Xcode
26.2 `appintentsmetadataprocessor` metadata diagnostic described in
[`project-baseline.md`](../architecture/project-baseline.md); every compiler or
other tool warning fails the command.

## Troubleshooting

| Symptom | Resolution |
| --- | --- |
| `Xcode 26.2 (17C52) is required` | Prefer a per-command selection: `DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer ./scripts/docs_smoke_fixture.sh`. Install Xcode 26.2 build 17C52 if that path is unavailable. The project is intentionally not validated with older Xcode versions. |
| `No available iPhone Simulator found` | In Xcode Settings > Components, install an available compatible iOS Simulator runtime, then create an iPhone simulator in Xcode Devices and Simulators. |
| A supplied `TEAM_D_SIMULATOR_UDID` is rejected | Remove the override and let the script choose, or supply the UDID of an available iPhone Simulator from `xcrun simctl list devices available`. |
| Test times out while booting | Quit Simulator/Xcode, run `xcrun simctl shutdown all`, and rerun the command. This does not require project configuration or service credentials. |
| Warning check fails | Treat it as a build failure. Only the exact documented AppIntents metadata diagnostic is allowlisted; fix or report every other warning. |

## Timed clean-clone checklist

Run this on a new macOS user or clean machine and record the elapsed wall time.
Start the timer immediately before `git clone`; stop it at the first successful
fixture UI test. Do not count Xcode download time.

| Check | Target | Record |
| --- | --- | --- |
| Xcode 26.2 and an available compatible iOS runtime | before start | Xcode build and runtime name (local evidence: iOS 18.5; CI pin: iOS 26.2) |
| Clone and open workspace | ≤ 10 min | start/end timestamps |
| Select or boot Simulator | ≤ 15 min total | simulator name and UDID |
| Run `./scripts/docs_smoke_fixture.sh` | ≤ 60 min total | command output with `TEST SUCCEEDED` |
| Confirm no secrets, Docker, backend, LiveKit, or camera were needed | required | `yes` / exception and owner |

T02-03 is not complete until this checklist has a reviewed clean-environment
proof. This document intentionally does not claim that proof.

Scope: this baseline verifies only the cold fixture launch UI test. The complete
four-photo fixture flow and its failure paths are owned by T17-03.
