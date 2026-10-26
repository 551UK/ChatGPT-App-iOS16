#!/usr/bin/env python3
"""Add our signed app shell to the main Mach-O so no jailbreak tweak is required."""
from pathlib import Path
import sys
import lief

path = Path(sys.argv[1])
load_name = "@executable_path/Frameworks/ChatGPTShell.dylib"
fat = lief.MachO.parse(str(path))
if fat is None or fat.size == 0:
    raise RuntimeError(f"Cannot parse Mach-O: {path}")
for binary in fat:
    if binary.find_library(load_name):
        raise RuntimeError("App shell already injected")
    command = binary.add_library(load_name)
    if command is None:
        raise RuntimeError("Mach-O library insertion failed")
fat.write(str(path))
check = lief.MachO.parse(str(path))
assert check is not None and all(b.find_library(load_name) for b in check)
print("Verified main executable loads ChatGPTShell.dylib")
