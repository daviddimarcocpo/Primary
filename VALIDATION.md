# Version 0.3.0 validation

## Scope

Current acceptance target: import STP/STEP/SLDPRT in local Tube Design and export a fresh single-part TEOX. Auto Run and nesting work is explicitly paused. Its earlier code and saved metadata are retained but those controls are not presented in the current interface.

## Evidence used

- User's Tube Design 17.0.56 screenshots, manual workflow recording, native toolbar/UI reports, and original Assembly Beam2 STEP/SLDPRT/TEOX exports.
- Recording at approximately 00:36 shows the Export production data tooltip over the toolbar location mapped to 41737 in the archived toolbar tree (production data toolbar 59431).
- Approximately 00:38 shows the save prerequisite; 00:40 shows the exact model-save dialog title; 00:42 shows the export panel.
- The training workbook documents automatic creation of a model-named subfolder on first save.
- The user confirmed manual import after using the correct TRUMPF starter, helper Identify opening, and prior assisted package collection. Direct helper import and this new export path remain unverified locally.

## Cloud checks

90 checks passed using PowerShell 7.4.6 on Linux. All helper files parse and the C# Win32 adapter compiles, without calling its Windows entry points. Actual uploaded TEOX metadata, BREP and binary STL were read. Tests cover exact document titles, candidate paths for all three filename extensions, unchanged/changed exports in both default locations, ambiguous outputs, wrong provenance, invalid units, empty or multiple geometries, short STL, and prohibited XML DTDs. Previous metadata/staging/resume/final-package and Auto Run file regressions also pass.

Extension tests are output-path planning tests, not CAD conversion or live import tests. No source-file modification, local TRUMPF launch, live save/export, engineering geometry comparison, simulation, or machine operation was tested in the cloud. Original customer CAD/NC files are not shipped in the ZIP.

## Required Windows acceptance

1. Resume or prepare the known sample with Tube Design started normally.
2. Test native file dialog import and inspect the actual loaded model.
3. Confirm profile and marking in Tube Design.
4. Test Begin TEOX export, save-prerequisite handling and Fill model save dialog.
5. Confirm intended export selection/settings in Tube Design.
6. Verify that a genuinely fresh TEOX is saved in its native location and the helper reports a successful container check.
7. Inspect/resume after a missing control, overwrite prompt or timeout without accepting unrelated dialogs automatically.

The watcher/controls must not be called fully working until those local steps are confirmed. A successful TEOX container check is not a downstream machine-readiness certification.
