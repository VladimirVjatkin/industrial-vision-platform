#!/usr/bin/env python3
"""Compile and run the standalone C tests with a host compiler."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "telemetry.c"
test = root / "tests" / "test_telemetry.c"


def find_msvc():
    base = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Microsoft Visual Studio"
    for path in sorted(base.glob("*/*/SDK/ScopeCppSDK/vc*/VC/bin/cl.exe"), reverse=True):
        return path
    return None


def compile_and_run(tmp):
    compiler = os.environ.get("CC") or next(
        (name for name in ("clang", "gcc", "cc", "cl") if shutil.which(name)), None
    )
    msvc = find_msvc() if sys.platform == "win32" and not compiler else None
    if not compiler and not msvc:
        raise SystemExit("No host C compiler found. Install GCC/Clang or use a Visual Studio developer shell.")
    exe = Path(tmp) / ("test_telemetry.exe" if sys.platform == "win32" else "test_telemetry")
    env = os.environ.copy()
    if msvc or Path(compiler).name.lower() in ("cl", "cl.exe"):
        if msvc:
            compiler = str(msvc)
            vc = msvc.parent.parent
            kit_root = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Windows Kits" / "10"
            kits = sorted((kit_root / "Lib").iterdir(), reverse=True)
            kit = kits[0]
            includes = [vc / "include", kit_root / "Include" / kit.name / "ucrt",
                        kit_root / "Include" / kit.name / "shared", kit_root / "Include" / kit.name / "um"]
            libs = [vc / "lib", kit / "ucrt" / "x64", kit / "um" / "x64"]
            env["INCLUDE"] = ";".join(map(str, includes))
            env["LIB"] = ";".join(map(str, libs))
        cmd = [compiler, "/nologo", "/W4", "/WX", "/TC", f"/I{root}", str(source), str(test), f"/Fe{exe}"]
    else:
        cmd = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
               f"-I{root}", str(source), str(test), "-o", str(exe)]
    print("Compiling with", Path(compiler).name, flush=True)
    subprocess.run(cmd, cwd=tmp, env=env, check=True)
    subprocess.run([str(exe)], cwd=tmp, check=True)


with tempfile.TemporaryDirectory(prefix="esp32-telemetry-host-") as tmp:
    compile_and_run(tmp)
