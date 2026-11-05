"""Usage: python3 scripts/tests/test-stage-runtime.py EXTRACTED_CYGWIN_ROOT.

Exercise the real staging script against an extracted release; no Windows VM.
"""
import hashlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

script = Path(__file__).resolve().parents[1] / "stage-runtime.sh"
source = Path(sys.argv[1]).resolve()
original_rg = source / "usr/local/bin/rg.exe"
before = hashlib.sha256(original_rg.read_bytes()).digest()
with tempfile.TemporaryDirectory(prefix="test-cygwin-stage-") as directory:
    work = Path(directory)
    stage = work / "cygwin"
    subprocess.run(["bash", str(script), str(source), str(stage)], check=True)
    assert hashlib.sha256(original_rg.read_bytes()).digest() == before
    assert (stage / "bin/sh.exe").samefile(stage / "bin/bash.exe")
    assert (stage / "bin/awk.exe").samefile(stage / "bin/gawk.exe")
    for command in "head tail sort find wc xargs uniq cut tr awk tar gzip sleep wget curl".split():
        assert (stage / "bin" / (command + ".exe")).is_file(), command
    assert (stage / "usr/local/bin/rg.exe").stat().st_size <= original_rg.stat().st_size
    sections = subprocess.check_output(["objdump", "-h", str(stage / "usr/local/bin/rg.exe")], text=True)
    assert ".debug" not in sections
    before_imports = subprocess.check_output(["objdump", "-p", str(original_rg)], text=True)
    after_imports = subprocess.check_output(["objdump", "-p", str(stage / "usr/local/bin/rg.exe")], text=True)
    assert re.findall(r"DLL Name:\s+(\S+)", before_imports) == re.findall(r"DLL Name:\s+(\S+)", after_imports)
    assert "_dll_crt0" in after_imports
    for relative in ("etc/ssl", "etc/pki", "etc/localtime", "etc/timezone",
                     "usr/share/zoneinfo", "usr/share/pki", "usr/share/ca-certificates",
                     "var/lib/ca-certificates", "etc/setup", "usr/share/misc",
                     "usr/share/groff", "usr/share/mintty", "bin/vi.exe",
                     "bin/mintty.exe", "usr/sbin/sshd.exe"):
        assert not os.path.lexists(stage / relative), relative
    assert not any(p.suffix in {".pem", ".crt", ".p11-kit"} for p in stage.rglob("*"))
    subprocess.run(["bash", "-n", str(stage / "etc/profile")], check=True)
    snapshot = {str(p.relative_to(stage)): p.stat().st_size for p in stage.rglob("*") if p.is_file()}
    result = subprocess.run(["bash", str(script), str(source), str(stage)], capture_output=True, text=True)
    assert result.returncode != 0 and "Refusing to overwrite" in result.stderr
    assert snapshot == {str(p.relative_to(stage)): p.stat().st_size for p in stage.rglob("*") if p.is_file()}
    broken = work / "missing-dll-source"
    shutil.copytree(source, broken, symlinks=True, copy_function=os.link)
    (broken / "bin/cygwin1.dll").unlink()
    result = subprocess.run(["bash", str(script), str(broken), str(work / "broken")], capture_output=True, text=True)
    assert result.returncode != 0 and "cygwin1.dll" in result.stderr
    print("PASS: exclusions, stripped ABI artifact, source preservation, overwrite refusal and missing-DLL failure")
