#!/bin/sh
# Build a separate, unflashed Samsung 4 KiB MMU diagnostic Image.
set -eu
cd "$(dirname "$0")"
mkdir -p out4k
. ./toolchain.sh
"${CC}" $A5_TARGET_FLAGS -c -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-pie -nostdlib \
    -fno-asynchronous-unwind-tables \
    -mgeneral-regs-only -march=armv8-a probe4k.S -o out4k/probe4k.o
"${CC}" $A5_TARGET_FLAGS -c -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-pie -nostdlib \
    -fno-asynchronous-unwind-tables -Wall -Wextra -Werror \
    -mgeneral-regs-only -march=armv8-a -O2 mmu4k.c -o out4k/mmu4k.o
"${LD}" -static -T probe4k.ld --build-id=none out4k/probe4k.o out4k/mmu4k.o \
    -o out4k/probe4k.elf
"${OBJCOPY}" -O binary out4k/probe4k.elf out4k/Image
python3 - <<'PY'
from pathlib import Path
import struct
p = Path("out4k/Image").read_bytes()
assert len(p) < 0x200000
assert p[56:60] == b"ARMd"
assert struct.unpack_from("<Q", p, 8)[0] == 0x205000
assert struct.unpack_from("<Q", p, 16)[0] == 0
print(f"out4k/Image: {len(p)} bytes; legacy Samsung Image header OK")
PY
