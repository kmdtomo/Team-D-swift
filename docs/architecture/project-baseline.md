# T02-01 project baseline

## Pinned toolchain

| Item | Baseline | Reason |
| --- | --- | --- |
| Xcode | 26.2 (17C52) | Installed toolchain used to create and verify this native iPhone scaffold. |
| Swift | 6.2.3 compiler, Swift 6 language mode | The compiler bundled with the pinned Xcode; `SWIFT_VERSION=6.0` selects the stable Swift 6 language mode. |
| Minimum iOS | 18.0 | Supports the iPhone SwiftUI/AVFoundation/Vision APIs required by the MVP while the installed 18.5 Simulator permits deterministic fixture validation. |
| Verification Simulator | iPhone 16 Pro, iOS 18.5 | Available locally and used by the T02-01 build-for-testing command. |

No package generator, external build system, or third-party dependency is introduced at this stage. The `TeamD.xcworkspace` contains the app project, and the project references the local `Packages` Swift package.

### Xcode 26.2 metadata-tool warning boundary

`ENABLE_APP_INTENTS_METADATA_PROCESSING=NO` is set for all `Debug-Fixture` targets. Xcode 26.2 nevertheless emits the following non-source-tool warning while it invokes `appintentsmetadataprocessor` for targets with no AppIntents dependency: `Metadata extraction skipped. No AppIntents.framework dependency found.` It is an Xcode tool diagnostic, not a compiler warning and has no app source location or remediation. `scripts/check_xcode_warnings.py` permits only this exact diagnostic and fails the build evidence for every other warning; it does not suppress compiler warnings.

Use the explicit Simulator architecture below so Xcode does not emit its ambiguous-destination driver warning:

```sh
xcodebuild -workspace TeamD.xcworkspace -scheme TeamD -configuration Debug-Fixture \
  -destination 'platform=iOS Simulator,id=9CF57E09-7DD0-4C17-9A98-7ECA8A9BD89A,arch=arm64' \
  build-for-testing CODE_SIGNING_ALLOWED=NO
```

## Directed dependencies

```text
DomainKit
├── ContractKit ──> APIClient
├── CaptureKit ───> LiveKitBridge
├── MeasurementKit
└── CompositionKit

TestSupport ──────> all production modules (test-only)
TeamD app ────────> all production modules
```

`TestSupport` is never imported by a production module. `scripts/lint_package_graph.py` checks that the local package targets remain present, resolve only to known local targets, and are acyclic.
