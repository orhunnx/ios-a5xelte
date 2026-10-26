# 0244: restore terminal ordering after0243 visual regression

## Physical regression and recovered log

The user reports black, discontinuous updates around the moving Clock icon
hands. The photograph shows striped black blocks inside that icon while the
adjacent Settings icon remains intact. Correct visual output is a required
gate; the increased update count below is not a successful performance result.

Read-only SYSTEMflush52 contains544744 recovered bytes/6232 decoded lines,
without ring overwrite. It records37GPU/216CPU panel copies and214GPU fallbacks,
compared with1fallback in0242b. Peak actual copy rate is5.092/s versus2.201/s in
0242b, under different uncontrolled workloads.507shown records include251
self/missing-source records. Reconstructed presentation cost is7.593ms/copy;
that mix includes CPU copies and is not an isolated GPU timing.

All64 captured command-buffer results are Completed/error0. All22 sampled
groups complete/status0, including two count6,one count7 and one count8;
last sampled group896. Upload receipts show actual cross-CB reuse, zero new
allocations in later samples and retained1/result0/uncertain0. Recorded fences
complete without MMU faults; there is no kernel panic or SpringBoard/backboardd
crash. One driverkitd memory-limit kill remains. Early sampled panel/source
pixel agreement does not prove the later Clock frame or producer timing correct.

The new CPU wall receipts help narrow steady rendering: sampled CB64/128/192
take about91.0/91.2/83.2ms commit-to-terminal, with roughly0.2ms dispatch wait
and0.03..0.05ms dependency wait. Corresponding sampled backend lock acquisition
is about9..10us; operation processing is65..69ms and final drain16..27ms.
CB numbers and backend serials are different sequences; do not pair them as
identical buffers. Early startup work is much slower, up to seconds. These
samples do not support removing the global transport lock as the main steady
performance fix. A later distinct fragment compilation wait is also captured;
no new shader publication is added in0244, keeping this ordering trial isolated.

## Concrete ordering gap

0243 published Scheduled and dispatched scheduled handlers before
`_privateBuffer commitAndWait`. That backend still reads shared/no-copy source
bytes, builds immutable native snapshots and launches synchronous kernel work.
Thus acceptance was observable before those CPU bytes were consumed.

Separately, the framebuffer's present bridge has no producer-fence dependency
in its SwapEnd ABI. `a5g3d_frame_present` probes the shared GPU queue without
waiting; contention returns CPUFallback, and the framebuffer then reads the
source on the CPU. A source may therefore be presented before its producer
completes. This is a concrete unsafe ordering, consistent with the new fallback
spike and physical regression. The log does not timestamp the exact Clock pixel
overwrite, so a complete causal A/B or exclusion of every other issue is not
claimed.

## Repair

Remove the early Scheduled transition and early scheduled-handler dispatch.
Both scheduled/submitted acceptance and terminal callbacks again wait until
the existing backend returns with real terminal fences. Dependency retirement,
resource ownership and the ordered callback fallback remain. This restores the
prior conservative presentation ordering. A future real overlap implementation
must provide producer dependencies to IOMFB and consume/retain the necessary
CPU data before announcing readiness. It cannot rely on a software-worker state
alone.

The8-draw matched ABI and terminal idle-upload reuse remain unchanged. This
single scheduling change provides a useful next physical comparison; they are
not declared free of all hardware regressions by host tests alone.

## Tests, build and installation

The actual Metal/IOSurface alias test holds the native transport fence and now
requires scheduled and completed notifications, submitted acceptance and CPU
alias reads to remain blocked until terminal completion. After release, all
notifications/order/cleanup pass under ASan/UBSan. Running this new contract
test against the exact0243 API source fails the blocked-notification assertion,
after actual query/emitter execution; it is not an allocation/compile failure.

The rebuilt iOS16/A53 provider/probe pass whole-bundle signing and4096-byte
CodeDirectory checks. Full XNU make returns0; actual403-file installer
stream/policy preflight and final linked-segment/payload CRC checks pass.
39publications,270 original selected-app files/metadata, all7PosterBoard files
and its resource seal, loader/DTBH/config are preserved.

Kernel25451128B; BOOT26118160B, SHA256
`66de58409a7c47e81369e4930dbd1aa8cc4ff2a03a478cc7aa32263e37604cb9`.
Guarded recovery/model/canonicalBOOTp10/capacity checks pass; all26118160bytes
are acknowledged, sync0 and reboot requested. No backup/readback/hash or whole
USERDATA transfer. The user was asked to check the Clock icon and scrolling,
then return to TWRP. Corrected physical output and FPS remain pending.
