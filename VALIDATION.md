# Version 0.1.4 validation

## Reference evidence

User-supplied STEP, recorded two-minute manual workflow, final TPC, and Production Package PDF:

- Job: CODEX TEST 10262026 SQ6X25
- Machine: TruLaser Tube 7000 (T12)
- Part: Assembly Beam2, quantity 10
- PDF reports two 240-inch stock tubes and estimated job time 00:09:25
- Reference ZIP CRC check passed using Python `zipfile.testzip()`
- Original uploads are kept outside this repository and are not included in the helper distribution.

## Checks run in the cloud

Core and syntax tests run using official PowerShell 7.4.6 for Linux. Its download was checked against the release's official SHA-256 manifest. This tests the PowerShell core against the actual supplied files, but is not a Windows PowerShell 5.1 runtime test. The helper uses PowerShell 5.1-compatible syntax and Windows built-in assemblies.

**51 checks passed**, including starter-shortcut routing regressions, compilation of the native Win32 adapter, and tests that reject missing/hidden/disabled commands or a wrong process/toolbar identity. The test transcript is included as `TEST RESULTS.txt` in the helper ZIP. Release file checksums are included as `SHA256SUMS.txt`. No test result should be interpreted as a live desktop or machine test.

## Local acceptance still required

1. Launch the unsigned helper under the workstation's existing execution policy.
2. Create a fresh sample job and confirm originals are preserved.
3. Try Import working copy and confirm the expected model loads. If that works, try Identify profile; confirm the right profile yourself.
4. Apply the recorded marking, export/register TEOX, and complete programming/nesting through the guided steps.
5. Export a new named PDF/TPC pair, review the PDF and nest, and run Check and collect package.
6. Complete the shop's normal simulation and operator release. No machine operation has been tested from this environment.

Auto Run control automation beyond guided steps is not implemented in this release. A new application-control report can support the next iteration without retrying licensed API calls.

## Startup correction

The initial helper preferred sldworks.exe over the TRUMPF starter. A local test subsequently reported "Starter application not run correctly", including for manual import. Version 0.1.1 removes this direct launch and shell-opens the installed normal Tube Design shortcut, retaining startup arguments and working directory. Automated tests verify starter selection, rejection of direct sldworks shortcuts, retention of route settings, and deduplication. Windows startup and successful CAD import remain pending local confirmation.

## Toolbar lookup correction

The new user-supplied report shows both expected toolbar names and native control IDs, but zero button children. This supports a missing-accessibility-children diagnosis, not a conclusion that command IDs changed. Version 0.1.2 queries TB_COMMANDTOINDEX and TB_GETSTATE on a uniquely matched visible native toolbar before using the existing WM_COMMAND route. Those scalar queries use no remote process memory. Tests compile the C# adapter without invoking its Windows entry points and exercise rejection conditions for the state validator. The actual native query and resulting Import/Identify operations remain unverified on Windows.

Privilege mismatch detection and enhanced control-report output are also implemented but require local Windows verification.

## Save-beside-input workflow

Output guidance and pickers now follow TRUMPF's default input-folder save behavior. Three added regression checks cover the working-copy folder before TEOX registration, the registered TEOX folder, and matching the PDF picker to the selected TPC folder. Existing generated folders are neither removed nor required. No desktop toolbar behavior changed in this update; Import/Identify remain subject to local verification.

## Filename mismatch diagnosis and correction

Mismatch messages now identify the saved helper name, expected filenames, and selected filenames. The existing wrong-PDF-name test verifies those diagnostic values. Three additional checks cover saving a corrected helper name while preserving the job directory and staged CAD, clearing earlier package approval, and rejecting invalid names. The Windows input dialog and label rendering remain subject to local verification. No filename or TPC content is changed by correcting the helper's name.
