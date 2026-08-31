# Deterministic fixture runbook

## Scope and separation

This is the Xcode-only service boundary: Xcode and an iPhone Simulator are the
only product-development dependencies. No Docker, local backend, LiveKit
project, API credential, network provider, or physical camera is required.
The fixture badge must read `テストデータ`.

Fixture success is fixture evidence only. It is not a live health, Room,
camera-publish, Agent-push, rembg, background-generation, or device result.

## Xcode-only path

1. Use macOS with Xcode 26.2 (17C52), its bundled Swift 6.2.3 compiler, and an
   available iPhone Simulator. The app deployment target is iOS 18.0.
2. Clone the repository, then open `TeamD.xcworkspace` in Xcode.
3. Select the shared `TeamD` scheme and an iPhone Simulator. The shared scheme
   uses `Debug-Fixture` for Run and Test.
4. Press Command-U. For the shortest deterministic confirmation, run
   `TeamDUITests.testColdLaunchEntersCameraFlowWithoutHomeOrTabs`.
5. Confirm the first screen remains in the camera flow and the visible mode
   badge says `テストデータ`. Do not configure live URLs or credentials.

This route currently proves the deterministic cold fixture launch. The full
four-photo fixture flow and its failure matrix remain owned by T17-03 and must
not be inferred from this check.

## One-hour evidence path

Start a timer immediately before clone and stop it after the first successful
fixture UI test. Xcode download time is outside the measurement. From the
repository root, the canonical reproducible command is:

```sh
./scripts/docs_smoke_fixture.sh
```

The total clone-to-success time must be at most 60 minutes. Record:

- repository commit and clean-clone location category (never a user name or
  image path);
- Xcode build, Simulator model/runtime, start/end timestamps, and elapsed time;
- the exact test identifier and `TEST SUCCEEDED` result;
- warning-check result and whether repository status stayed unchanged;
- confirmation that no secret, Docker, backend, LiveKit, or camera was needed.

The detailed timing sheet and Simulator selection behavior are maintained in
[the fixture baseline](../development/fixture-baseline.md).

## Expected result

The command must report the selected Simulator, a successful single fixture
UI test, zero unexpected warnings, elapsed seconds no greater than 3600, and an
unchanged repository status. A test failure or dirty worktree is failure
evidence, not a reason to switch configurations.

## Fixture troubleshooting

- Wrong Xcode: select Xcode 26.2 (17C52) for this command. Do not reinterpret a
  different toolchain result as the pinned baseline.
- No Simulator: install a compatible iOS Simulator in Xcode Settings and
  create an iPhone device in Devices and Simulators.
- Boot timeout: shut down stuck Simulators, reopen Xcode, and rerun the same
  fixture command.
- Unexpected warning: treat it as a failed evidence run and inspect the build
  log without uploading it if it contains user paths.
- Live-style failure or missing network: verify that `Debug-Fixture` and the
  `テストデータ` badge are selected. Fixture must never need a live service.

Continue with [failure isolation](troubleshooting-and-privacy.md) if the same
fixture command fails twice for the same reason.
