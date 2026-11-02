# a5xelte iOS 16 bring-up

Target: SM-A510F, Exynos 7580. Donor: this repository's sweet XNU 8796 and iOS 16 userland. Baseline commit: 11da58bd050672960c0a83b5bef2176047eea479. The donor README reports a SpringBoard boot on Redmi Note 10 Pro. The a5xelte XNU build and first device entry are verified separately below.

## First device milestone

Keep the working postmarketOS BOOT checkpoint and private backups. Use a separate a5xelte configuration. First prove that one CPU enters a Samsung-specific shim and XNU and produces recoverable text diagnostics. Do not prepare the iOS root or change USERDATA for this milestone.

Run `python3 tools/a5xelte-preflight.py` on the existing Linux installation. It reads the live device tree. The CPU feature value is useful only when supplied from a trusted raw EL1 capture: Linux masks the TGran16 field in its EL0 CPU register emulation, so a userspace `MRS` result of zero does not prove the hardware value. A raw EL1 measurement on this device has now confirmed the 16 KiB incompatibility; see below.

The Linux port already captured a Samsung handoff at EL1 (CurrentEL 0x4), wrapper load 0x40205000 and FDT 0x48000000 in its attempt3 recovery log. Recheck these against the selected working BOOT before building the XNU shim; do not treat them as universal firmware constants. Samsung uses a 2048-byte Android BOOT header with DTBH; the donor's Xiaomi boot.img v2 and `fastboot boot` path do not apply. Use the existing port's guarded BOOT packaging and recovery route only after a candidate passes offline checks.

## Live CPU granule result (2026-10-19)

The running 7.2.8 a5xelte Linux kernel reported MIDR_EL1 `0x410fd033` (Cortex-A53 r0p3). A temporary GPL module built against that exact kernel read `ID_AA64MMFR0_EL1=0x00000000001122` at EL1; `TGran16[23:20]=0`. The module was unloaded and its tmpfs copy removed. This is a device-side register observation, not an XNU boot. Arm's Cortex-A53 TRM defines zero as no 16 KiB translation granule.

The donor's `shim/mmu.c` uses `PG_SHIFT=14`, `TG0=16K`, `TG1=16K` and 2048-entry page tables; `SWEET.h` defines `__ARM_16K_PG__`. These cannot be reused on this CPU. The a5xelte path must use 4 KiB tables and a distinct XNU board configuration compiled for ARMv8-A. Apple's XNU 8796 BCM2837 board config demonstrates an ARM64 target without `__ARM_16K_PG__`, but the donor's GICv3, timer and storage paths still require Exynos-specific replacements. iOS 16 userland operation on a 4 KiB XNU kernel remains unverified.

The reproducible register probe is in `tools/a5xelte-mmfr0/`. Build it with `make -C "$KDIR" M="$PWD/tools/a5xelte-mmfr0" modules` against the exact running kernel. Loading a module is a live kernel operation; run it only on the lab device and remove it immediately afterward.

## Separate 4 KiB MMU diagnostic

`shim/a5xelte/build-probe4k.sh` builds a Samsung Image for a single-core EL1 test. It verifies 4 KiB granule support, constructs 4 KiB L1/L2/L3 identity tables, enables the MMU, records TCR/SCTLR and a result code in the reserved ramoops page, then requests TWRP recovery through the Exynos7580 PMU reset-mode registers. The probe itself does not access block devices. The host packer and flash operation are separate.

On 2026-10-19 the packaged probe was written to BOOT p10 after its ramdisk, DTBH and header digest were checked against the working image. Readback matched the candidate. The ordinary `reboot` command did not restart the shell-based Linux system; `reboot -f` did. The phone entered TWRP automatically. The TWRP `/proc/last_kmsg` capture contained `A5XNU001` with CurrentEL `0x4`, SCTLR before `0x30c5183e`, FDT `0x48000000`, Image `0x40205000`, `ID_AA64MMFR0_EL1=0x1122`, result `4`, TCR after `0x80a03520`, and SCTLR after `0x30c5183f`. This is a **live 4 KiB MMU result**, not XNU execution. The captured `CNTFRQ_EL0` was zero; the Exynos timer path needs separate attention. At the user's request the Linux BOOT image was not restored. No USERDATA, EFS or recovery partition was written.

`xnu/patches/0082-a5xelte-4k-entry.patch` is a first XNU entry variant: it removes the donor's 16 KiB page selection, limits initial SMP to one CPU, skips the donor framebuffer writes and places an XNU-owned physical entry marker in reserved log RAM. `0083` accommodates Xcode 27's generated `IORPC.kernelContent` references, and `0084` selects the 36-bit device user VA limit so the 4 KiB commpage nesting assertion holds. The donor GICv3, timer, UFS and framebuffer paths are still incompatible with Exynos7580; the marker is only an entry checkpoint.

`shim/a5xelte/build-xnu-boot.sh` builds a separate 6 KiB Samsung Image loader. It reads the bootloader's `/chosen/linux,initrd-*` payload range, checks the `SWEETXNU` container and an isolated 512 MiB RAM window at `0x80000000`, copies Mach-O segments and the ADT, creates 4 KiB-aligned boot arguments, and jumps to the XNU physical entry. Failures request TWRP; the successful jump leaves a reserved-RAM marker for later recovery. The loader was first compiled with the VM's ARMv8-A cross toolchain; it now builds on macOS with Homebrew LLVM or a GNU AArch64 ELF toolchain ([build notes](a5xelte-build-macos.md)) and has no ELF relocations. Its first device run reached the XNU entry marker; the evidence is recorded below.

`tools/mkadt_a5xelte.py` generates an entry-only ADT with the Exynos7580 GICv2 node and no storage node. `tools/a5xelte-pack-probe.py --ramdisk` packages an XNU payload in a Samsung BOOT image while keeping the reference DTBH. The donor 16 KiB XNU cannot execute its MMU setup on this CPU and **must not be flashed**.

## Local XNU build and first BOOT attempt (2026-10-19)

Xcode 27.1 on macOS 27.2 built `kernel.development.sweet` with the a5xelte 4 KiB patch set. The 13.5 KDK package payload was expanded into a temporary directory and passed as `KDKROOT`, avoiding a system-wide installation. A local `blacktop/darwin-xnu-build` checkout at `663906528d1cd5ea8fde7de6f16de73db9511549` performed the build. The resulting arm64 Mach-O was 19 MB, SHA-256 `f093a6bc0d8f9c060f6dc4429810f768e00ec3f093ca624f1cd2694bd9a9b444`. The 4 KiB path compiled past `pmap_insert_commpage_internal`'s page-shift assertion. This is build evidence, not device execution evidence.

The entry-only ADT was 3,356 bytes. `mkpayload.py` produced a 19,940,288-byte `SWEETXNU` container; the Samsung BOOT candidate with the 6 KiB loader was 19,990,544 bytes, SHA-256 `8dff262ad0934b71396900eefef2ce34b681f0574e5e37ba065fc7482cff5921`. The candidate was written to BOOT p10 from TWRP, and p10 readback matched the candidate hash. TWRP `adb reboot` started the test. The user observed a persistent Samsung logo, then entered TWRP with the keys. Its `/proc/last_kmsg` preserved both `A5XNU002` at offset `0x7cde2` and the XNU-owned `XNUELTE1` at `0x7cee2`, exactly `0x100` bytes apart as the loader and XNU marker addresses specify. Loader slots showed EL1 (`0x4`), FDT `0x48000000`, Image `0x40205000`, state `5` (ready to branch), payload `0x42000000..0x433043c0`, isolated RAM `0x80000000..0xa0000000`, entry PA `0x81423488`, ten Mach-O segments, and boot args PA `0x827f5000`. **This proves execution reached XNU's `start_first_cpu` entry marker on the phone.** It does not prove the MMU transition, interrupt controller, timer, root filesystem or iOS userland. USERDATA, recovery and EFS were not written.

## Board map from the existing Linux port

These are Linux-source facts, not XNU runtime proof. References: `mainline/exynos7580-a5xelte-minimal.dts`, `mainline/exynos7580-a5xelte-native.dts` and `mainline/package-boot.py` in the sma510fpmos workspace.

| Item | a5xelte | sweet assumption to replace |
| --- | --- | --- |
| CPU | Eight Cortex-A53; MPIDR 0..3, 0x100..0x103; PSCI 0.1 SMC | Kryo A55/A76 topology |
| Interrupts | GICv2 distributor 0x10c01000 and CPU interface 0x10c02000 | GICv3 redistributors and ICC system registers |
| Timer | 26 MHz; virtual timer PPI 11, INTID 27 | 19.2 MHz; INTID 19 |
| RAM | Starts 0x40000000; excludes firmware and multimedia reservations | Upper bank at 0x100000000 |
| Storage | DesignWare eMMC at 0x13540000, SPI 245 | Qualcomm UFS and ufsroot0 |
| Boot | Android BOOT plus DTBH rev3 for hardware rev4; BOOT p10; observed EL1 handoff | Temporary Xiaomi fastboot boot |
| Data | Linux USERDATA is in use; EFS p3 and recovery p11 preserved | HFS+ root in USERDATA |

The diagnostic DTS explicitly calls itself a scaffold. Check addresses against the installed BOOT DTB and read-only runtime evidence before hard-coding them.

## Implementation order

1. A5xelte shim: the raw EL1 granule result and live 4 KiB MMU transition are complete. Build a Samsung payload loader for the 4 KiB XNU variant. Do not attempt the donor's 16 KiB MMU setup. Compile for baseline ARMv8-A.
2. A5xelte XNU machine config: GICv2 interrupt acknowledgement, timer PPI and one CPU. Then test PSCI secondaries.
3. Recoverable panic log, eMMC read-only and root-device identification.
4. Exynos display, touch and keys using downstream Linux and Lineage source as hardware references.
5. iOS 16 root/userland only after memory and storage sizing: this board has 2 GiB RAM and about 11.5 GiB USERDATA, so the donor's 16 GiB root-image command is unsuitable as written.

Build output, kernel observations and user-verified screen/input behavior must be recorded separately. The only partition operation in this branch's live test was the explicitly authorized diagnostic BOOT p10 write.

## C console and Cortex-A53 build

The early assembly renderer prints fixed XNU-owned strings before C initialization. The A5XELTE framebuffer serial node is `a5xelte-fbcon` at physical `0x67000000`. With the 39-bit kernel VA fix, the phone displayed dynamic XNU C startup and a panic on `ldadd` after `cpu_bootstrap`. The donor's DEVELOPMENT `kprintf` path is disabled by default, even with `debug=0xc`; the donor notes require `-enable_kprintf_spam` once `serial_init` runs. Pass an explicit command line to `tools/mkpayload.py`:

```sh
--cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
```

The A5's Cortex-A53 requires `-mcpu=cortex-a53` for *all* kernel C and C++ objects; `-march=armv8-a` alone leaves Xcode's Apple M1 default CPU and emits unsupported LSE atomics. Patches `0094`–`0096` also disable PAN and replace the commpage's `casa` operations with ARMv8.0 LL/SC trylocks. The independently built libdispatch firehose archive must be rebuilt before the final XNU link:

```sh
tools/a5xelte-build-firehose.sh /path/to/darwin-xnu-build
```

The helper uses the already staged libdispatch and fakeroot, verifies the resulting arm64 archive contains no LSE instructions, and installs it into that local build tree. Remove the old `kernel.development.a5xelte.unstripped` output before relinking so XNU includes the replacement archive. The local build may still fail at `dsymutil` on `/dev/fd` after successfully linking the unstripped Mach-O. Do not use the donor's `rd=ufsroot0`, `sweetfb_*`, UFS or USERDATA arguments on this device.

## RAM disk root probe (2026-10-20)

The first A5XELTE build with the built-in libpthread provider passed its earlier panic and reached the BSD root wait for `IOMedia` with `Content=Apple_HFS`. To test the in-memory path without partitioning USERDATA, format an empty 8 MiB HFS+ file in a private temporary directory and pass it to `tools/mkpayload.py --ramdisk` with `rd=md0` in the command line. The packer adds `/chosen/memory-map/RAMDisk` to the ADT; `tools/a5xelte-pack-probe.py --ramdisk` then embeds the resulting XNU payload in the Samsung BOOT image. Keep the stock BOOT reference and generated images outside Git, check the 32 MiB BOOT size limit, and compare the exact p10 readback before reboot.

On the physical phone the kernel printed `Added memory device md0/rmd0` and `BSD root: md0`. It then panicked at `IOService.cpp:5200` because `IOBlockStorageDriverClass` is absent. The donor already permits its RAM disk boot without IOStorageFamily under `ARM64_BOARD_CONFIG_SWEET`; the A5XELTE build did not select that guard. This is a class-availability assertion, not evidence that the empty HFS+ volume mounted. No disk partition other than BOOT p10 was written.

Patch `0103` enables the same no-IOStorageFamily RAM disk guards for A5XELTE. On the next phone boot the kernel printed `hfs: mounted A5XNU on device ... (st: 0)` and attempted `/sbin/launchd`. The empty test volume has no executable at that path, so process 1 panicked with `errno 2` at `kern_exec.c:6929`. This is a verified root mount and userland exec attempt, not an iOS userland boot. An actual iOS root will require OS/SystemOS/AppOS contents and an A5XELTE storage path larger than BOOT's 32 MiB limit; the donor's 16 GiB image cannot fit this phone's roughly 11.5 GiB USERDATA as-is. Prepare and size that root privately only after the XNU storage path is established. The current test still writes only BOOT p10.

## IPSW source selection

The user chose iPhone 8 Plus as the userland source because its display class is closer to the A5XELTE panel. The downloaded IPSW was moved into ignored `research/ipsw/` and inspected without extracting or writing to the phone:

```sh
python3 tools/a5xelte-inspect-ipsw.py research/ipsw/iPhone_5.5_P3_16.7.16_20H392_Restore.ipsw
```

BuildManifest reports iOS 16.7.16 (20H392), `iPhone10,5`/`iPhone10,2`, and both `d211ap` and `d21ap` erase/upgrade identities. Each references OS `087-86694-044.dmg` (4,723,392,522 bytes), `Cryptex1,SystemOS` `087-86588-047.dmg` (2,743,074,816 bytes), and `Cryptex1,AppOS` `087-86715-047.dmg` (10,485,760 bytes). The DeviceTree paths are `Firmware/all_flash/DeviceTree.d211ap.im4p` and `Firmware/all_flash/DeviceTree.d21ap.im4p`. These are ZIP member sizes, not the installed root size. The donor `tools/mkadt.py` and userland services still assume iPhone X / `D22AP`; no iPhone 8 Plus identity has been applied to the A5XELTE boot tree.

Next, choose and validate one actual iPhone 8 Plus identity, adapt the A5XELTE device identity and display service, and construct a root within a verified storage budget. The user first authorized replacing Linux SYSTEM p20 with a dedicated HFS+ root. After the 3 GB SYSTEM budget proved too small, the user also authorized erasing all of USERDATA p23 for a larger iOS root. Do not copy the donor's `D22AP` device tree, 16 GiB image size, UFS path or Xiaomi flashing command into the Samsung procedure.

## First Exynos7580 eMMC read probe

Patch `0104` adds `bsd/dev/a5xelte_emmc.c` to the A5XELTE build. `tools/mkadt_a5xelte.py` supplies the Exynos7580 eMMC MMIO window from the working Linux port. The first trial used `emmcprobe=1 rd=md0` to read GPT LBA1 while keeping the HFS RAM disk root. The second phone run exposed the hardware FIFO issue: XNU's single 64-bit SFR read duplicated the lower word, while Linux's working source uses paired 32-bit reads at `DATA` and `DATA+4`. With that pair, the phone printed `read-only GPT LBA1 OK, entries=128, ver=270a, fifo=64-bit`. This proves one device sector read, not a mounted disk root.

## Dedicated HFS+ SYSTEM root

The user explicitly authorized erasing Linux SYSTEM p20 and using it as the HFS+ root. TWRP identifies SYSTEM as `/dev/block/mmcblk0p20`, exactly 3,145,728,000 bytes. A private read of GPT sectors 0–33 shows a Samsung 512-byte header with a valid CRC and a valid 128-entry table CRC. The `SYSTEM` entry spans LBA 507904–6651903, exactly 6,144,000 sectors. The new `emmcroot0` BSD device accepts only that named range, issues CMD17 reads, and refuses writes. The root boot argument is `rd=emmcroot0`; it is independent of the donor SWEET UFS path. The dedicated HFS+ image is journaled, 3,145,728,000 bytes, and remains outside Git. It is initially empty, so a successful mount should still end at the missing `/sbin/launchd` step. Do not claim iOS userland until its files are present and actually execute on the phone.

The full p20 write and readback hashes match. The first physical boot selected `/dev/emmcroot0` and printed `hfs: mounted A5XNU on device b(1, 0)`, proving the persistent HFS root is readable by XNU. It then panicked at `rootvp not authenticated after mounting @bsd_init.c:947`: the empty HFS volume has no Image4 seal. Patch `0105` applies the donor's unsigned-root behavior to A5XELTE with an A5XELTE-specific log. The next phone photo shows `A5XELTE: root volume is not authenticated (error 25); continuing unsealed`, then attempts `/usr/appleinternal/sbin/launchd.development` and `/sbin/launchd`. Process 1 panicked with `errno 2` because the HFS volume is empty. This proves root mount and exec lookup, not iOS userland execution.

## USERDATA root budget and first-stage selection

The iPhone 8 Plus IPSW remains ignored under `research/ipsw/`. Three image members were extracted into private temporary storage and mounted read-only on macOS with original owners enabled. Apparent contents are about 7.49 GiB for OS, 3.13 GiB for SystemOS (mostly the dyld shared cache), and 8 MiB for AppOS. Their full combined size leaves too little headroom in the 11.25 GiB USERDATA partition. `tools/a5xelte-stage-ios-root.sh` omits stock applications and large optional language, asset, health, watch, assistant, onboarding and audio data for the first SpringBoard-focused trial. It keeps SpringBoard, frameworks, launchd and the complete dyld cache, and hard-links cryptex files into the expected paths. This is a size-oriented first stage, not evidence that SpringBoard can run without the omitted assets.

The existing GPT USERDATA entry spans LBA 7,184,384–30,769,151: 23,584,768 sectors or exactly 12,075,401,216 bytes. A private case-sensitive HFSX sparse image with that exact virtual size was staged and checked with `diskutil verifyVolume`. It holds about 8.7 GiB of the selected OS and cryptex files. Patch `0104` accepts `emmcroot=USERDATA` alongside its default `SYSTEM` selector; `rd=emmcroot0` remains the BSD name. The driver remains read-only. In TWRP, the source stream and USERDATA p23 write both completed at exactly 12,075,401,216 bytes. The user asked to skip a full partition hash comparison; the transfer length is the available check, not a content readback.

The next phone photo shows `hfs: mounted A5IOSROOT on device b(1, 0)` and the unsealed root path continuing to the first `/sbin/launchd` exec. XNU then faults at `accelerate_entitlement_queries` while `ubc_cs_blob_add` processes that binary: `amfi` is NULL because the donor's built-in AMFI interface was compiled only for `ARM64_BOARD_CONFIG_SWEET`. Patch `0106` compiles and registers that interface and its XML-entitlements provider for A5XELTE, with A5XELTE runtime labels. It provides the interface required by the exec path; this lab port does not add a production code-integrity chain. The corresponding kernel linked as an arm64 Mach-O; the later `dsymutil` step failed on `/dev/fd/62` as in prior builds. The 20,219,920-byte BOOT candidate was written only to p10, its `ANDROID!` header read back, and the phone rebooted.

The following device photo shows `launchd` executing: libignition enters PID 1 and dyld opens the shared-cache directory. XNU rejects the cache's CodeDirectory page shift 14 (16 KiB), since this A53 kernel uses 4 KiB VM pages. Dyld cannot register the cache signature, then cannot load `libSystem.B.dylib`, so launchd exits. The separate `ignition_level=1` warnings explain cryptex selection but are not the immediate fatal path. Patch `0107` accepts the 16 KiB directory as metadata on A5XELTE, avoids reading 16 KiB from a 4 KiB VM page for validation, and disables shared-region code-signing enforcement for this lab target. The new BOOT uses `cs_enforcement_disable=1`; its 20,217,872 bytes were written only to p10 and its Android BOOT header read back. The next phone photo shows launchd's bootstrap message, `fsck`, and `mount-phase-1`. The dyld cache blocker is passed. The mount task then fails because `/dev/emmcroot0` is read-only, and its status 1 exit triggers a launchd panic.

Patch `0108` implements CMD24 single-sector writes in the XNU eMMC driver. It follows the working downstream Linux driver's two 32-bit FIFO writes per 64-bit word, with the 64-word depth declared in the a5xelte device tree. `emmcwrite=1` permits writes only if GPT selected `USERDATA`; every request remains bounded by that partition's LBA range. `SYSTEM` is still read-only. The first writable BOOT candidate was linked and written to p10, and the phone was rebooted. A successful writable HFS mount or USERDATA write has not yet been observed on screen.

On that boot the user reported passing `system boot started`; a later phone photo shows launchd attempting many service spawns, including `xpcproxy`, `passd`, `tccd`, and `biomed`, without a visible panic. It also shows a `logd_helper` high-CPU warning. This is device evidence of continued PID 1 progress after the old mount-task failure. The photo does not establish that those services stayed running, that a sector write completed, or that SpringBoard launched. Keep the current boot running and use a later `SpringBoard` process line or actual graphical output as the next distinct checkpoint.

A subsequent photo shows `A5XELTE Sandbox: containermanager op 16` and `op 15` alongside more service spawns, including `PowerUIAgent`; it still does not show SpringBoard. The donor `SWEET AKS` prefix remains on some compatibility messages. Current XNU early text proves DECON scanout, but the A5XELTE build excludes the donor `AppleCLCD` framebuffer, and its ADT has no `disp0` IOMobileFramebuffer provider. A display-service bridge is needed before the user can see a SpringBoard frame even if that process starts.

Patch `0109` is the first local display-service candidate. It enables the donor's CPU-presented IOSurface/IOMobileFramebuffer interface only where A5XELTE's DECON scanout buffer already exists, maps physical `0x67000000` at 1080×1920 with 4320-byte rows, and adds an A5XELTE `disp0` service in the ADT. The Linux handoff driver supplies the register and scanout reference; XNU does not yet perform cold DECON/DSI initialization. The active phone boot remains on patch `0108`, so a local build or ADT check must not be confused with graphical device proof.

The A5XELTE variant also has a console mute hook, enabled by `a5fb_noconsole=1` only after its first framebuffer present, with panic text still shown. The local XNU Mach-O linked with the framebuffer symbols and the Samsung BOOT candidate is 20,252,688 bytes, below the 32 MiB BOOT limit. The next physical test must distinguish: framebuffer service registration, IOSurface use and actual frame presentation, and SpringBoard process start. The current photo still shows repeated `bluetoothd`/`xpcproxy` spawn attempts and a `symptomsd` sandbox denial, with no SpringBoard record.

The candidate was transferred through Mac ADB in TWRP and written only to BOOT p10; the `ANDROID!` header was read back before reboot. USERDATA p23 was not rewritten. The phone display result is pending.

For kernel changes, rebuild and transfer only BOOT p10. The populated USERDATA HFSX volume stays on p23. Future root file changes can be staged as targeted filesystem edits from TWRP rather than retransferring the entire 11.25 GiB image. The new XNU write path needs a device result before being counted as working.

## Persistent console log candidate

Patch `0110` adds an opt-in 4 MiB console ring for the A5XELTE build. With `a5log=1`, `emmcroot=USERDATA`, and `emmcwrite=1`, a kernel thread flushes it every 10 seconds to the first 8,193 sectors of GPT SYSTEM p20. The old `A5XNU` test HFS volume there is sacrificed; the iOS root remains on USERDATA p23. The GPT header and entries must pass CRC checks, the SYSTEM and USERDATA ranges must not overlap, and the sector writer checks its target against one of those ranges. BOOT, RECOVERY, EFS, and the GPT are not log targets.

The first physical recovery read returned flush #329 and 234,303 bytes. It confirms that the persistent logger works. The same log records repeated SpringBoard, backboardd, bluetoothd, and fairplayd.H2 spawn authorizations, but no framebuffer swap/present event. Patch `0111` adds bounded crash diagnostics to distinguish service exits from mere launch attempts. Patch `0112` prepares a two-core trial: CPU1 has MPIDR 1 in the verified Exynos7580 Linux topology, and GICv2 supplies banked per-core interrupt state. The kernel reads the shared physical counter because firmware-provided virtual-counter offsets differed across CPUs in the working Linux port. Neither the XNU second core nor a graphical frame is verified until the phone reports it.

After a test, return to TWRP and read the log with `tools/a5xelte-log-pull.sh /private/path/boot-log.txt`. The helper writes a raw `.bin` beside the decoded text; both may contain device identifiers and userland messages, so keep them outside Git. The `A5XLOG1` header records total bytes and flush sequence. A missing header means the device has not successfully flushed a log yet; it is not proof that XNU never started. The first physical readback has not been performed yet.
