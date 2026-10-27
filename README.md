# Tube Design Helper 0.3.0

The current scope is **STP / STEP / SLDPRT -> Tube Design -> TEOX**. Auto Run, nesting, PDF/TPC collection, and machine operation are paused in this interface. Their saved job metadata and previous files are retained. This is assisted desktop automation, not an unattended converter, and it does not use the denied TRUMPF API.

## Start here

1. Download the helper ZIP from your repository. If Windows marks that ZIP as downloaded, use its Properties > Unblock on that specific trusted package, then extract into a new folder. Launch Start Helper.cmd. Do not change machine-wide execution policy.
2. Resume your existing job.json, or prepare a new batch with STP, STEP or SLDPRT inputs. Original CAD is copied into originals and a separate work folder. Use the staged copies. Quantity and stock inputs are hidden because this stage does not need them; previous values remain in resumed jobs.
3. Open Tube Design using its normal TRUMPF shortcut or the helper's Open Tube Design button. It never starts sldworks.exe directly. Save any existing work and close the current part before testing a new import, so its title cannot be mistaken for the new result.
4. Click Import working copy. The helper uses the recorded Import command, identifies a unique owned native file dialog, verifies its filename edit and Import button, writes/readbacks the exact staged path, and requests Import. It stops if those identities are unavailable. Inspect the actual displayed part before continuing; requesting import does not prove the model loaded correctly.
5. Click Identify profile, select the intended body, review dimensions/material/profile/direction, and accept in Tube Design. A checkbox in the helper records your review; it does not operate the green check for you.
6. Apply cutting/marking choices in Tube Design and confirm them. For the sample, BEAM2 lettering is marking. Do not apply that assumption to other jobs. Acknowledge processing review in the helper.
7. Click Begin TEOX export. It snapshots existing candidate outputs and invokes the verified Export production data toolbar command. The ID 41737 / toolbar 59431 mapping comes from the archived native control tree and the recording's visible Export production data tooltip. An absent/disabled/ambiguous command is not dispatched.
8. If Tube Design asks to save the document first, accept that prerequisite yourself. When **Name of the tube design model to be stored** appears, click **Fill model save dialog** in the helper. It fills the same-name SLDPRT in the working-copy folder and requests Save. Review any overwrite prompt yourself; the helper does not answer generic confirmations.
9. In Export production data, review the selected tube and export settings, then accept Tube Design's green check. Keep normal TRUMPF save-beside-input behavior, including the model-named child folder it can create on first save.
10. The helper watches for a fresh same-name TEOX in those two default locations, validates its container/model metadata, and registers it automatically. If it takes longer than two minutes, complete the dialogs and click Check TEOX export. Stop watching leaves Tube Design running. If your actual output folder differs, use Register exported TEOX to select the file explicitly inside this helper job.

## What TEOX validation means

The check requires a nonempty bounded ZIP, safe unique member names, a well-formed COLLADA document without DTD/external entity resolution, one geometry with BREP or mesh content, matching source model basename, positive finite units, and a matching nonempty binary STL preview with a consistent triangle count. The input reference produced 5,876 triangles. Other valid parts do not need that same count. A file hash before/after inspection detects changes during reading.

The export watcher requires changed output after the request; an unchanged cached TEOX does not count. If both candidate locations change, it asks you to choose explicitly. It never renames, repairs, synthesizes, or edits TEOX geometry to make validation pass. Geometry/units/source metadata checks do **not** prove engineering dimensions, processing intent, manufacturability, collision clearance, or downstream machine readiness. The operator's profile/marking review remains necessary.

A successful check saves TeoxPath and a diagnostic check report. The native TRUMPF output stays in its input/model folder. No separate generated folder is required. A manually selected TEOX receives the same structural checks. Inputs containing multiple separately manufactured tube geometries require separate preparation; this release handles one exported geometry per part.

## Current verification and remaining local work

90 syntax, adapter-compilation, file-format, staging, resume, and metadata checks pass in the Linux cloud using PowerShell 7.4.6. The official runtime download was SHA-256 verified. None of its Win32 calls were executed in those cloud tests. Windows PowerShell 5.1 is the workstation target and requires no additional Python or package install.

The user confirmed that normal Tube Design startup restores manual import, that the earlier helper opens Identify profile, and that the prior assisted job can be collected successfully. This does **not** verify the new native import, save-dialog filling, Export command, or export watcher on Windows. Test those with the known Assembly Beam2 example before extending to more parts. Native filename controls and toolbar commands are bounded by process/window identity and enabled state; no coordinates, global keystrokes, unknown buttons, license bypasses, or remote process memory are used.

If an action stops, leave the relevant Tube Design dialog open and click Save control report. Version 0.3 captures Tube Design only, with deeper controls, help text, pattern names and native Import/Identify/Export state. Review the report before sharing; it may include job names and paths. Diagnostic capture does not click controls or take screenshots. Runtime logs and job.json remain in your existing batch folder. Resume expects that folder to stay at its original location.

The launcher requests RemoteSigned for its own PowerShell process; it does not elevate itself or permanently modify policy. If the normal TRUMPF shortcut runs elevated, the helper detects the mismatch and explains it. Run both at the normal matching level used by your workstation. Application privilege or provider issues remain possible until locally tested.

## Developer tests

Provide the original reference files locally; none of the customer CAD/NC uploads are bundled in the distribution:

```powershell
pwsh -NoProfile -File tests/Test-Core.ps1 `
  -ReferenceTpc 'C:\samples\CODEX TEST 10262026 SQ6X25.tpc' `
  -ReferencePdf 'C:\samples\CODEX TEST 10262026 SQ6X25.pdf' `
  -ReferenceCad 'C:\samples\Assembly Beam2.stp' `
  -ReferenceTubx 'C:\samples\Assembly Beam2.tubx' `
  -ReferenceTeox 'C:\samples\Assembly Beam2.teox'
```

Tests include actual reference TEOX parsing; rejection of wrong source, multiple/empty geometries, invalid units, malformed preview and XML DTDs; default-location export freshness; exact document-title matching; and all previous file-level regressions. Extension-path tests do not simulate CAD import or claim that three CAD formats have been imported on Windows. See VALIDATION.md and the packaged TEST RESULTS.txt.

For development packaging, run tools/Build-Package.py after the tests. Python is needed only for packaging, not to run the delivered helper.

Each cloud task already runs in an isolated checkout. Use the existing checkout; do not create a Git worktree unless explicitly requested by the user.
