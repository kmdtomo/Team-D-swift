# Team-D notices

Inventory reviewed: 2026-08-31. The current app target has no external Swift
package and no resource files in its resource build phase. Therefore no
third-party library or binary is presently included in the app bundle by this
baseline.

`output/pdf/t11-01-50mm-marker.pdf` is a first-party generated repository
artifact, not an app resource. Its generator manifest records ReportLab 4.4.9
as BSD-3-Clause, but ReportLab code is not bundled in the app or PDF.

The fixed Web-source fixture candidates are unlicensed for redistribution and
were not copied. LiveKit Swift is pending a future package pin; OpenCV iOS is
not adopted; rembg and BiRefNet are shared backend services and their models
are not bundled. No Web code or Web notice has been copied or inherited.

See `dependency-inventory.json` for source, version, checksum, review date,
and the explicit pending inputs required before release.
