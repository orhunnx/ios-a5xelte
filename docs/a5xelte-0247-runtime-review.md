# 0247 runtime — normal wakeup latency, later compiler queue blockage

After a transient USB absence, the same a5xelte TWRP device becomes visible.
Read-only SYSTEM capture: flush48,596610raw console bytes/6349 decoded lines,
no ring overwrite. Decoded text is596365bytes after CR removal/UTF8 handling.
No device write or follow-up image installation was performed in this readout.

## GPU completion and frame delivery

64 captured CB results are Completed/error0. All13 sampled native groups
complete/status0:6size1,4size2 and3size7, last group320.32 native receipts are
status0/MMU0;228 AS0 fences complete/MMU0; eight4096-point panel/source grids
have zero RGB/alpha mismatch. There is no captured native-phase failure,
resource rejection, kernel panic, SpringBoard/backboardd or PosterBoard crash.
The bounded diagnostics do not prove all later buffers succeeded.

There are112GPU/3CPU panel copies and0GPUfallback. Peak reported10.2shown/s
includes no-ops; peak actual-copy rate is5.130/s. Reconstructed copy cost12.305ms
versus0246's12.921ms.96intervals cover510879ms,80zero-shown. This is a shorter,
different workload than0246 and does not establish an overall FPS improvement.
The user supplied TWRP-return status without a subjective speed comparison.

Only nine backend timing records are captured. One9operation record costs
85.739ms versus0246's14sample median90.145ms. Two34operation records have median
3193.796ms versus3190.914ms in0246. There are no comparable10/11operation samples.
The aggregate median of these different scenes must not be used as a regression
or speedup comparison.

## What the new polling measurements establish

The2ms spin limit is present in actual native and AS0 receipts.

| Sample class | Count | No sleeps | With sleeps | Weighted actual sleep call |
| --- | ---: | ---: | ---: | ---: |
| Native |17|8|9|1.196ms|
| AS0 typed/presentation |8|6|2|1.198ms|

This capture does not support the earlier hypothesis of routine12ms scheduler
oversleep. Long native intervals still contain many ordinary1.2ms sleeps while
the job remains pending. A sampled602 fragment takes189.874ms, with187.262ms in
157 sleeps and1.997ms accounted spin. Several other fragments take9..16ms.
Short vertex/tiler stages complete without sleeping. Samples are sparse and
biased by decimation; these are not full GPU active-cycle measurements.

Therefore extending the spin window alone does not remove the large drawing
cost. Whole-render-pass/tile-list work and GPU clock/throughput need separate
measurement; no OPP/frequency change or fence removal has been made here.

## Separate compiler stall blocks later UI work

The daemon dispatches one fragment, successfully spawns/observes the exact
metal2vulkan executable, but records no translator output or exit/publication.
The latest RUNNING receipt is301.3seconds, with approximately0.477ms child user
CPU and31.138ms system CPU, log_bytes0 and one accounted process. This is not
evidence of301seconds of actual shader compilation. It indicates little
userspace progress; a wait/page-in/startup block remains to be located.

Later backboardd waits repeatedly for a different fragment identity. Both
requests have compilerABI2. The synchronous run() loop blocks a5ScanRequests
until the current child returns, so a new request cannot be dispatched meanwhile.
The current job is not identified as old-maintenance in this capture: its exact
arrival/priority is unknown. A fairness/starvation consequence is demonstrated;
the underlying child-block reason is not yet established.

A193024B bounded read of project-only HFS paths retrieves both requests, with no
published stage or request-status result for either. Both exact originals then
compile through the actual Mac worker/translator/released Mesa backend to3440B
and4544B native fragments. Native/reflection hashes and the production stage
cache loader pass. These private host publications are prepared, not installed;
no phone pixel or generic phone-worker repair is claimed. This separates a
supported AIR/backend request from the phone execution/dispatch problem.

The next compiler fix should locate the child wait and ensure background/older
work cannot indefinitely block a newly demanded render function, retaining
request authentication, real compilation and terminal publication. A timeout
must not be reported as shader success or an unsupported-operation verdict.

## Other observations

Only one process crash is recorded: driverkitd namespace1/code7 memory-limit
SIGKILL.3touch and62key HID records are present. No new wallpaper-state evidence
is captured; absence of a PosterBoard crash does not repair selectedLockPath.
Final eMMC counters show2150055424read bytes,61839360write bytes and0errors.
Raw logs, request identities and native shaders remain in private build storage.
