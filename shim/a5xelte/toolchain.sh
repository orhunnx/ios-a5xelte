#!/bin/sh
# Select an AArch64 bare-metal toolchain for the Samsung loader and probes.
#
# The loader and probe images are freestanding ELF binaries. The host cc/ld on
# macOS produce Mach-O, so these scripts need a cross target. Selection order:
#   1. CC, LD and OBJCOPY from the environment (all three together)
#   2. GNU aarch64-elf-* (for example a cross toolchain installed with Homebrew)
#   3. Homebrew LLVM: clang --target=aarch64-none-elf, ld.lld, llvm-objcopy
#
# Sourced by build-xnu-boot.sh, build-probe.sh and build-probe4k.sh; it sets
# CC, LD, OBJCOPY and A5_TARGET_FLAGS.

a5_tc_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [ -n "${CC:-}" ] || [ -n "${LD:-}" ] || [ -n "${OBJCOPY:-}" ]; then
    if [ -z "${CC:-}" ] || [ -z "${LD:-}" ] || [ -z "${OBJCOPY:-}" ]; then
        a5_tc_die "set CC, LD and OBJCOPY together, or leave all three unset"
    fi
    A5_TARGET_FLAGS=${A5_TARGET_FLAGS:-}
    return 0 2>/dev/null || exit 0
fi

gnu_prefix=
for triple in aarch64-elf aarch64-none-elf aarch64-linux-gnu; do
    if command -v "$triple-gcc" >/dev/null 2>&1 &&
       command -v "$triple-ld" >/dev/null 2>&1 &&
       command -v "$triple-objcopy" >/dev/null 2>&1; then
        gnu_prefix=$triple
        break
    fi
done

if [ -n "$gnu_prefix" ]; then
    CC=$gnu_prefix-gcc
    LD=$gnu_prefix-ld
    OBJCOPY=$gnu_prefix-objcopy
    A5_TARGET_FLAGS=
    return 0 2>/dev/null || exit 0
fi

brew_llvm=
if command -v brew >/dev/null 2>&1; then
    brew_llvm=$(brew --prefix llvm 2>/dev/null || true)
fi

llvm_bin=
for candidate in "${LLVM_PREFIX:+$LLVM_PREFIX/bin}" "$brew_llvm/bin" /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/clang" ] && [ -x "$candidate/llvm-objcopy" ]; then
        llvm_bin=$candidate
        break
    fi
done

if [ -n "$llvm_bin" ]; then
    ld_lld=$(command -v ld.lld 2>/dev/null || true)
    if [ -z "$ld_lld" ] && [ -x "$llvm_bin/ld.lld" ]; then
        ld_lld=$llvm_bin/ld.lld
    fi
    [ -n "$ld_lld" ] || a5_tc_die "ld.lld not found; install Homebrew lld (brew install lld)"
    CC=$llvm_bin/clang
    LD=$ld_lld
    OBJCOPY=$llvm_bin/llvm-objcopy
    A5_TARGET_FLAGS="--target=aarch64-none-elf"
    return 0 2>/dev/null || exit 0
fi

a5_tc_die "no AArch64 bare-metal toolchain found; install Homebrew LLVM (brew install llvm lld) or set CC, LD and OBJCOPY"
