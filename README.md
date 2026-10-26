# Tube Job Helper

A local Windows assistant for preparing TRUMPF tube-laser jobs and collecting the **Production Package PDF and nested TPC**. Built around the supplied Tube Design 17 / Programming Tube Auto Run 7.0.1 demonstration for TruLaser Tube 7000 (T12).

**Version 0.1 is an assisted workflow, not unattended CAD-to-machine programming.** It does not require a TRUMPF API license. Its Import and Identify commands use ordinary visible Tube Design controls and still require a first test on the programming workstation. Auto Run, nesting, contour selection, and export remain guided operator actions in this release. No simulation, machine operation, network transfer, or USB copy is performed.

## First run

1. Extract the complete helper ZIP into a normal folder on your Windows computer. Keep the `helper` subfolder beside `Start Helper.cmd`.
2. Double-click **Start Helper.cmd**. It uses built-in Windows PowerShell 5.1 and .NET; there is no Python or additional package installation.
3. If Windows blocks execution, stop and share the actual message. The launcher requests `RemoteSigned` for its PowerShell process only; it does not permanently change execution policy, elevate privileges, or disable Windows controls. This prototype is not code-signed, so managed policy or downloaded-file restrictions may prevent it from launching.
4. Start with the known **Assembly Beam2** example rather than a new production job. Choose its STEP file, set quantity **10**, stock **240 inches**, and job name **CODEX TEST 10262026 SQ6X25**. The helper creates a new unique folder, so the previous job is retained.
5. Follow the three tabs. Original CAD files are retained unchanged in `originals`. Import and save only from the new `work` folders. Expected output names follow the original CAD base name.

The first desktop test is **Import working copy** with Tube Design open at its normal screen. It should open the recorded Import dialog, enter the staged path, and request import. Inspect the displayed part before continuing. If the control is unavailable, the helper stops with an explanation; use the import command manually. It never tries substitute toolbar IDs, coordinates, or global keystrokes.

## The three tabs

**Prepare job** accepts STEP/STP/SLDPRT files, quantities, a job name, and stock length in inches. The default 240-inch stock is visible and editable, not inferred from the CAD. A fresh timestamp/ID folder is created for every new run. To continue after closing, choose **Resume saved job** and select that run's `job.json`; keep the job folder at its original location.

**Design and program** provides experimental **Import working copy** and **Identify profile** commands. You select/confirm the body, material, profile, dimensions, and direction. You assign and confirm cutting/marking contours. Save the SLDPRT and export a fresh, same-name TEOX into the part's working folder. Register that TEOX, open Auto Run, copy the TEOX path, and import it with the `+` button. Wait for calculation and inspect errors/warnings. Repeat for each part. One separately manufactured part per input CAD file is supported; multi-body assemblies need separate preparation.

**Nest and check outputs** lists exact part quantities and the requested stock length. In Auto Run select those parts, enter nesting, set each part's Min./Max. quantities, keep the job multiplier/Amount at 1, and review compatible material/profile groupings. Set the exact job name, recalculate, review the nest, and export the final named TPC and Production Package PDF into this run's `generated` folder. Select those two files in the helper. Open and review the PDF, acknowledge the review, and choose **Check and collect package**.

## What the checks establish

- The selected TPC is a readable ZIP with supported, complete program text and a nested-job header. Archive members are inspected in memory; nothing is extracted or executed.
- TPC header job name, part names, quantities, and T12 target match the prepared job. A part-only TPC, extra/missing parts, duplicate allocations, and unsupported header formats are rejected.
- Final TPC and PDF filenames match the job. The PDF has a PDF signature. **PDF contents are reviewed by you**, not decoded by this Windows release.
- Outputs selected in the UI are inside the current job folder and do not predate its creation. Changes to the PDF after its review require review again. SHA-256 checks preserve both collected files byte for byte.
- A completed pair is copied into a new `deliverables/package-...` folder only after checks and review. Existing packages are not overwritten. Failed collection can leave a `.pending-package-...` folder outside `deliverables`; do not use it.

These checks **do not establish** collision clearance, correct technology settings, correct marking, stock allocation encoded by the machine, PDF content agreement, ZIP CRC integrity independently of decompression, or machine readiness. The original uploaded reference TPC separately passed Python ZIP CRC testing during development. Always perform the shop's usual TRUMPF simulation and operator release for new output. The helper never creates or patches NC instructions, manufactures a TPC by editing a reference, or copies output to a machine.

## Troubleshooting

- Keep one visible Tube Design window. Run the helper and TRUMPF in the same Windows user/session, normally without administrator elevation.
- **Import/Identify** may stop if a dialog is open, Windows rejects foreground activation, or controls differ from the recorded installation. Inspect TRUMPF before retrying; a timed-out request may already have reached the application. Only the worker is terminated on a 15-second timeout; TRUMPF is left running.
- Use **Save control report** for a new local diagnostic. It records Tube Design/Auto Run control names and IDs only, capped at 1,000 entries and depth 6. No desktop screenshots, unrelated window enumeration, credentials, or network connections are collected. Review the report before sharing; names may contain job information.
- Runtime files are in your run folder: `job.json`, `helper.log`, `diagnostics`, generated files, and deliverables. Source code and unrelated user files are not modified.

## Developer validation

The core runs under PowerShell without Windows desktop assemblies. Supply the three original reference uploads locally:

```powershell
pwsh -NoProfile -File tests/Test-Core.ps1 `
  -ReferenceTpc 'C:\samples\CODEX TEST 10262026 SQ6X25.tpc' `
  -ReferencePdf 'C:\samples\CODEX TEST 10262026 SQ6X25.pdf' `
  -ReferenceCad 'C:\samples\Assembly Beam2.stp'
```

The suite parses all helper PowerShell files and exercises the actual TPC/PDF pair, expected identities/quantities, rejected mismatches, malformed inputs, collection hashes, source preservation, isolated job staging, and resume validation. It does not launch Windows Forms or validate live TRUMPF behavior. See `VALIDATION.md` for the run result and remaining acceptance work.

Each cloud task already has an isolated checkout. Use that checkout; do not create a Git worktree unless the user explicitly requests one.
