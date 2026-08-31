# T19-03 Phase 1 license inventory

`dependency-inventory.json` is the machine-readable source of truth for the
committed baseline. It deliberately records absences: no external SwiftPM
package, no `Package.resolved`, no app resource files, and no copied fixture
binaries. It does not claim a license when a dependency is only planned or a
source snapshot has no verified redistribution grant.

Run `python3 scripts/lint_t19_03_inventory.py` after changing a package
manifest, app resources, fixture provenance, the marker PDF, or these notice
files. The check is source-only and uses the Python standard library.

Phase 1 remains `code_ready_unverified`. T08, T11, and T14 must supply their
final inputs before the inventory can become a release inventory.
