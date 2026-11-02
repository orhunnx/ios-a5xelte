# Building the A5XELTE images on macOS

The Samsung loader and the two EL1 probes build on macOS. A Linux VM is not
required for them, and the XNU kernel is also built locally with Xcode and
`blacktop/darwin-xnu-build` as recorded in
[a5xelte-bringup.md](a5xelte-bringup.md).

## Toolchain selection

`shim/a5xelte/toolchain.sh` is sourced by `build-xnu-boot.sh`,
`build-probe.sh` and `build-probe4k.sh`. It selects:

1. `CC`, `LD` and `OBJCOPY` from the environment, when all three are set;
2. a GNU AArch64 ELF toolchain (`aarch64-elf`, `aarch64-none-elf` or
   `aarch64-linux-gnu` prefix);
3. Homebrew LLVM: `clang --target=aarch64-none-elf`, `ld.lld`,
   `llvm-objcopy`.

For the third path install `brew install llvm lld`. `llvm-objcopy` is
keg-only, so the script looks under `brew --prefix llvm`; it does not require
a PATH change.

## Loader

```sh
cd shim/a5xelte
sh build-xnu-boot.sh            # 512 MiB working checkpoint
RAM_MIB=736 sh build-xnu-boot.sh
```

The output is `outxnu/Image`, a 6 KiB Samsung loader with the 2048-byte
Android header. The script verifies the header and never packages or writes
BOOT.

Reproduction recorded on macOS 27.2 with Xcode 27.2, Homebrew LLVM 22.1.8 and
LLD 22.1.8:

| RAM_MIB | Bytes | SHA-256 |
| --- | --- | --- |
| 512 | 10336 | `522c365351f65f5f7459d03126b3b327c3f755363e11e614ecd69cc6b4efab37` |
| 736 | 10368 | `055a2886aa2146cdba20236da78862d23492eb0415063162915ca00d722c5632` |

Both images are byte-for-byte equal to the loaders recorded in
[the 736 MiB window note](a5xelte-736mib-lab-window.md). This is build
reproduction, not device execution.

## EL1 probes

```sh
sh build-probe.sh               # out/Image, 316 bytes
sh build-probe4k.sh             # out4k/Image, 20480 bytes
```

The scripts only build diagnostic Samsung Images. They do not write BOOT or
any other partition.

## XNU

The kernel still uses the local `darwin-xnu-build` checkout, Xcode and the
13.5 KDK package passed as `KDKROOT`; see
[the local XNU build record](a5xelte-bringup.md). Keep
`MACHINE_CONFIG=A5XELTE` and the 4 KiB patch series. The GitHub workflow
`xnu.yml` runs on a macOS runner, but its default machine config is `SWEET`;
do not treat that workflow as the A5XELTE build until it is changed.
