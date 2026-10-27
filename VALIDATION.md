# Version 0.1.1 validation

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

**37 checks passed**, including four starter-shortcut routing regressions. The test transcript is included as `TEST RESULTS.txt` in the helper ZIP. Release file checksums are included as `SHA256SUMS.txt`. No test result should be interpreted as a live desktop or machine test.

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
