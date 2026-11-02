#!/bin/sh
# Build a diagnostic Samsung Image. This script never packages or flashes BOOT.
set -eu
cd "$(dirname "$0")"
mkdir -p out
. ./toolchain.sh
"$CC" $A5_TARGET_FLAGS -c -ffreestanding -nostdlib -mgeneral-regs-only -march=armv8-a probe.S -o out/probe.o
"$LD" -T probe.ld --build-id=none out/probe.o -o out/probe.elf
"$OBJCOPY" -O binary out/probe.elf out/Image
python3 - <<'PY'
from pathlib import Path
import struct
p = Path("out/Image").read_bytes()
assert len(p) < 0x10000
assert p[56:60] == b"ARMd"
assert struct.unpack_from("<Q", p, 8)[0] == 0x205000
assert struct.unpack_from("<Q", p, 16)[0] == 0
print(f"out/Image: {len(p)} bytes; legacy Samsung Image header OK")
PY
