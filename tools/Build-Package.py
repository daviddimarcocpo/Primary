"""Build the Windows helper ZIP using Python standard-library tools only.

Python is needed for this developer packaging command, not on the workstation
where the delivered PowerShell helper runs. No customer CAD or NC is packaged.
"""
from hashlib import sha256
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
import re

version = "0.1.2"

root = Path(__file__).resolve().parents[1]
out = root / "artifacts"
out.mkdir(exist_ok=True)
files = [
    root / "Start Helper.cmd",
    root / "READ ME FIRST.txt",
    root / "README.md",
    root / "VALIDATION.md",
    *sorted((root / "helper").glob("*.ps*1")),
    root / "tests/Test-Core.ps1",
]
payload = {}
for path in files:
    text = path.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
    if path.suffix in {".cmd", ".ps1", ".psm1", ".txt"}:
        text = text.replace("\n", "\r\n")
    data = text.encode("utf-8-sig" if path.suffix in {".ps1", ".psm1"} else "utf-8")
    payload[path.relative_to(root).as_posix()] = data
test_log = out / "test-results.txt"
if not test_log.exists() or not re.search(r"Completed: [1-9][0-9]* checks passed\.", test_log.read_text()):
    raise SystemExit("Run the core reference tests successfully before packaging.")
payload["TEST RESULTS.txt"] = test_log.read_bytes()
manifest = "".join(f"{sha256(data).hexdigest()}  {name}\n" for name, data in sorted(payload.items()))
payload["SHA256SUMS.txt"] = manifest.encode("utf-8")
destination = out / f"Tube-Job-Helper-{version}.zip"
with ZipFile(destination, "w") as archive:
    for name, data in sorted(payload.items()):
        info = ZipInfo("Tube Job Helper/" + name, date_time=(2026, 10, 27, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, data)
with ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist()) == len(payload)
    for name, data in payload.items():
        assert archive.read("Tube Job Helper/" + name) == data
digest = sha256(destination.read_bytes()).hexdigest()
(out / (destination.name + ".sha256")).write_text(f"{digest}  {destination.name}\n")
print(f"Built and CRC-verified: {destination}")
print(f"Files: {len(payload)}; size: {destination.stat().st_size:,} bytes")
print(f"SHA256: {digest}")
