# iOS CI and merge gates

T19-01 fixes the reproducible fixture CI boundary. The workflow is
`.github/workflows/ios-ci.yml`, named `TeamD iOS CI`. It runs on `macos-26`
with Xcode 26.2 (17C52), `Debug-Fixture`, the iOS 26.2 Simulator runtime, and
an iPhone 17 Pro device type. Hosted execution is still pending because this
candidate has not been pushed.

## Required pull-request checks

Configure branch protection or a repository ruleset for the protected branch
with these exact job check names:

- `T19-01 Source gates`
- `T19-01 Fixture suite`

The first check runs traceability, fixture/hash governance, HTTP schema drift,
configuration and secret checks, the measurement corpus lint, license
inventory, package graph, and the CI linter/self-tests. Its adversarial test
changes a schema timeout, corrupts the fixed marker hash, and writes a
credential-shaped value in an isolated archive; every corresponding gate must
reject the mutation without printing the value.

The fixture check performs a clean local-package resolve, Xcode package
resolution, package build and full package tests, then `build-for-testing` and
`test-without-building` for all app unit tests and Simulator XCUITest. Every
Xcode log is checked by the warning policy, and the fixture app product is
checked for its build mode and embedded secrets. A failure in either required
check must block merge.

`T19-01 Protected live smoke` is deliberately not a PR required check. It can
run only when a maintainer selects `run_live_smoke` in `workflow_dispatch` and
the `teamd-ios-live-smoke` environment approves the run. It validates the
protected health and token contracts without building the app, logging the
response, or retaining the returned token. It does not claim the pending
T17/T18 full live or physical-device coverage.

## Repository-administrator setup

The following is a pending repository-administrator gate; Git cannot encode
or prove it:

1. Run `TeamD iOS CI` once on the protected branch so both check names are
   visible to GitHub.
2. In the branch ruleset (or branch protection rule) for `main`, require a pull
   request and require status checks to pass before merging.
3. Select exactly `T19-01 Source gates` and `T19-01 Fixture suite`, require the
   branch to be up to date before merging, and do not permit administrators or
   force-pushes to bypass failed required checks.
4. Create the `teamd-ios-live-smoke` environment with required reviewers and
   deployment-branch restrictions. Set the non-secret
   `TEAM_D_LIVE_BACKEND_BASE_URL` environment variable and the minimum-scope
   `TEAM_D_LIVE_SMOKE_BEARER` environment secret there. Never store LiveKit API
   secrets in GitHub Actions, the iOS app, repository configuration, or an
   artifact; the shared backend remains their sole owner.
5. Verify with a fork PR that no environment secret is made available and the
   live job is skipped. Verify with isolated test branches that each required
   check failure prevents merge.

Record the repository/ruleset URL, protection review date, administrator, and
one blocked-merge run in the Phase 2 verification evidence. Until that record
exists, branch protection and hosted-CI success remain pending acceptance
gates.

## Cache and artifact policy

The workflow has an explicit no shared cache policy: it does not use
`actions/cache`, restore a previous `.build` or DerivedData directory, or save
package/build caches. Each fixture run uses its own SwiftPM scratch directory,
cloned-source-package directory, DerivedData directory, module caches, and
temporary Simulator, then deletes the Simulator. The runner image may provide
Xcode and the pinned Simulator runtime, but it provides no project build
cache.

Source-gate logs are retained for 7 days. Fixture-only build/test logs and
`.xcresult` bundles are retained for 14 days. The workflow does not upload the
`.app`, DerivedData, SwiftPM scratch, live response, or live token. Fixture
artifacts are scanned before upload and must contain no credential, private
endpoint, user image, or live response. Artifact upload actions and checkout
actions are pinned to full commit SHAs rather than mutable tags.

## Local entry points

These commands are the same entry points used by CI:

```sh
./scripts/ci_source_gates.sh
./scripts/ci_fixture.sh
```

`ci_fixture.sh` requires Xcode 26.2 (17C52) and an installed iOS 26.2 runtime.
It creates an iPhone 17 Pro Simulator instead of reusing a developer device.
The protected live script fails closed outside the guarded manual workflow and
must not be run with credentials from an unprotected shell or PR job.
