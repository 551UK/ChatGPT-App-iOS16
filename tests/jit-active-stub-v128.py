"""Execute actual ARM64 paths with an unmapped next pointer, using Unicorn.

Trace callees are mocked; this verifies control flow, not full Gecko GC.
Unpatched paths must fault. Patched paths must trace exactly the active stub.
"""
import sys
import struct
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from patch_xul_active_stub import patch
from unicorn import Uc, UcError, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import *

original = Path(sys.argv[1]).read_bytes()
patched = bytes(patch(original))

def run(data, weak, fallback, null, next_pointer):
    uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    base = 0x696e000
    uc.mem_map(base, 0x2000)
    uc.mem_write(base, data[base:base + 0x2000])
    uc.mem_map(0x100000, 0x3000)
    stack, frame, stub, tracer = 0x100000, 0x101000, 0x102000, 0x200000
    uc.reg_write(UC_ARM64_REG_SP, stack)
    uc.reg_write(UC_ARM64_REG_X19, tracer)
    uc.mem_write(stack + (0x10 if weak else 0x48), struct.pack('<Q', frame))
    uc.mem_write(frame - 8, struct.pack('<Q', 0 if null else stub))
    uc.mem_write(stub + 13, bytes([1 if fallback else 0]))
    uc.mem_write(stub + 16, struct.pack('<Q', next_pointer))
    start = 0x696f8d4 if weak else 0x696e8d0
    end = 0x696f8ac if weak else 0x696e908
    call = 0x696f8f4 if weak else 0x696e8fc
    calls = []
    def hook(emu, address, size, _):
        if address == call:
            calls.append((emu.reg_read(UC_ARM64_REG_X0), emu.reg_read(UC_ARM64_REG_X1)))
            emu.reg_write(UC_ARM64_REG_PC, address + 4)
        elif address == end or (not weak and address == 0x696ea6c):
            emu.emu_stop()
    uc.hook_add(UC_HOOK_CODE, hook)
    try:
        uc.emu_start(start, 0, count=100)
    except UcError:
        return False, calls
    expected = [] if fallback or null else [(tracer, stub) if weak else (stub, tracer)]
    assert calls == expected, (weak, calls, expected)
    return True, calls

for weak in (False, True):
    assert not run(original, weak, False, False, 0xdead000)[0]
    for next_pointer in (0, 0xdead000, 0x102000):
        for fallback, null in ((False, False), (True, False), (False, True)):
            assert run(patched, weak, fallback, null, next_pointer)[0]
try:
    patch(patched)
    raise AssertionError('Double patch should fail')
except ValueError:
    pass
print('PASS: original stale-chain faults reproduced; 18 patched ARM64 cases passed; wrong hash rejected')
