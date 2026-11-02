#!/bin/sh
# Build the Samsung EL1 loader. No flash or payload packaging here.
set -eu
cd "$(dirname "$0")"
. ./toolchain.sh
mkdir -p outxnu
: "${RAM_MIB:=512}"
case "$RAM_MIB" in
    512|736) ;;
    *) echo "RAM_MIB must be 512 or the opt-in 736" >&2; exit 1 ;;
esac
# S-Boot enters with SCTLR_EL1.A=1 and M=0. Unaligned widened loads from
# byte arrays fault here, even though ordinary arm64 userspace permits them.
CFLAGS="-c -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-pie -nostdlib -fno-asynchronous-unwind-tables -mgeneral-regs-only -mstrict-align -march=armv8-a -Wall -Wextra -Werror"
"${CC}" $A5_TARGET_FLAGS $CFLAGS xnu_boot.S -o outxnu/xnu_boot.o
"${CC}" $A5_TARGET_FLAGS $CFLAGS -DA5XELTE_RAM_MIB="$RAM_MIB" xnu_boot.c -o outxnu/xnu_boot_c.o
"${CC}" $A5_TARGET_FLAGS $CFLAGS display_console.c -o outxnu/display_console.o
"${CC}" $A5_TARGET_FLAGS $CFLAGS ../fdt.c -o outxnu/fdt.o
"${LD}" -static -T xnu_boot.ld --build-id=none outxnu/xnu_boot.o outxnu/xnu_boot_c.o outxnu/display_console.o outxnu/fdt.o -o outxnu/xnu_boot.elf
"${OBJCOPY}" -O binary outxnu/xnu_boot.elf outxnu/Image
python3 - <<'PY'
from pathlib import Path
import struct
p = Path('outxnu/Image').read_bytes()
assert p[56:60] == b'ARMd'
assert struct.unpack_from('<Q', p, 8)[0] == 0x205000
assert struct.unpack_from('<Q', p, 16)[0] == 0
print(f'outxnu/Image: {len(p)} bytes; Samsung legacy Image header OK')
PY
