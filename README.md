# Team-D iPhone client

This repository is the camera-first native iOS client for Team-D. Its
deterministic fixture baseline needs no secrets, Docker, local backend, LiveKit,
or camera hardware:

```sh
./scripts/docs_smoke_fixture.sh
```

For the supported Xcode version, Xcode walkthrough, troubleshooting, and timed
clean-clone checklist, see [the fixture Simulator baseline](docs/development/fixture-baseline.md).
Fixture and live are distinct modes; this command verifies fixture only.
