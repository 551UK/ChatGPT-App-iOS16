#!/usr/bin/env python3
"""Restore upstream Baseline active-stub-only GC tracing in pinned Reynard XUL.

This is a device-test candidate, not a confirmed crash fix. Refuse any other
binary. The two branch edits preserve the active trace calls and local slots;
only Reynard's added traversal of subsequent stubs is bypassed. JIT stays on.
"""
import hashlib
import struct
import sys
from pathlib import Path

ORIGINAL_SHA256 = '4cc88d51a4ecb0fccd4235d8c6875ab76a5765f4e507786b0ff6b27c8e8e4819'

def branch(source, target):
    displacement = target - source
    assert displacement % 4 == 0 and -(1 << 27) <= displacement < (1 << 27)
    return struct.pack('<I', 0x14000000 | ((displacement // 4) & 0x3ffffff))

PATCHES = (
    # After ICCacheIRStub::trace, continue with active-stub local tracing slots.
    (0x696e900, bytes.fromhex('180b40f9'), branch(0x696e900, 0x696e908)),
    # After active traceWeak, advance the frame iterator, not the stale chain.
    (0x696f8f8, bytes.fromhex('03000014'), branch(0x696f8f8, 0x696f8ac)),
)

def patch(data):
    if hashlib.sha256(data).hexdigest() != ORIGINAL_SHA256:
        raise ValueError('Unsupported XUL hash; refusing to patch')
    result = bytearray(data)
    for offset, expected, replacement in PATCHES:
        if result[offset:offset + 4] != expected:
            raise ValueError(f'Instruction mismatch at {offset:#x}')
        result[offset:offset + 4] = replacement
    return result

if __name__ == '__main__':
    path = Path(sys.argv[1])
    result = patch(path.read_bytes())
    path.write_bytes(result)
    print('Patched two Baseline GC branches; sign XUL before packaging.')
    print('Unsigned patched SHA256:', hashlib.sha256(result).hexdigest())
