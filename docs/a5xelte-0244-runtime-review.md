# 0244 runtime: Clock corruption gone, rendering remains slow

The user confirms the Clock icon's striped/black corruption is gone but the UI
is still slow. This is physical evidence for the visual repair, not for a
performance improvement. No new image or device write was performed for this
readout.

## Capture and actual presentation

Read-only SYSTEM flush453 recovers1941868 raw bytes and19157 decoded lines,
without ring overwrite. Sampled framebuffer windows span4561293ms, about76min.
This includes idle time, different UI workloads, startup and process restarts;
it is not a controlled benchmark against0243.

There are2178 GPU and5 CPU panel copies, with3 GPU fallbacks versus214 in the
corrupt0243 capture.4369 shown records include2182 self/missing-source records.
Peak actual copy rate is8.433/s; reported16.8 shown/s includes no-ops and must
not be presented as rendered FPS. Reconstructed presentation cost is12.858ms
per actual copy; weighted pending age is28.711ms. Eight4096-point panel/source
grids have zero RGB/alpha mismatches, a bounded sample rather than every pixel
or proof that every later frame is correct.

## GPU completion and retained resources

All65 captured public command-buffer results are Completed/error0. All240
sampled native groups are complete/status0, with last sampled group14848.
Group sizes:155x1,33x2,19x3,10x4,2x5,17x6,3x7,1x8. Thus the eight-draw capacity
is exercised but most captured groups remain small. All32 native receipts have
status0, all4372 captured fence receipts complete with MMU0, and sampled native
phases have no nonzero result. No kernel panic or backboardd crash is recorded.
Upload receipts continue to show creates0/reused1/retained1/result0/uncertain0;
retained reuse works on the phone but does not eliminate all preparation cost.

## Where the time goes

Sampled timings are monotonic CPU wall durations, not GPU hardware timestamps.
The operation phase includes CPU preparation, user/kernel transport, intermediate
batch drains and GPU waits; its duration cannot be called pure CPU or GPU time.
Public CB identifiers and private backend serials are different sequences.

| Sampled phase | Samples | Median | Maximum |
| --- | ---: | ---: | ---: |
| Public dispatch queue |42|0.227ms|0.301ms|
| Public dependency wait |42|0.049ms|8.058ms|
| Public backend execution |42|84.533ms|3084.731ms|
| Public total |42|85.298ms|3092.329ms|
| Backend lock acquisition |43|0.011ms|0.027ms|
| Backend operations |43|67.661ms|3029.642ms|
| Backend final drain |43|17.105ms|255.052ms|
| Callback dispatch queue |42|2.891ms|36.679ms|

Workload-separated backend totals are more informative than the mixed median:

| Operations per backend submission | Samples | Total range | Median |
| --- | ---: | ---: | ---: |
|2|14|37.892..39.755ms|39.006ms|
|9|9|80.424..88.136ms|84.694ms|
|29|8|1346.946..1364.660ms|1355.199ms|
|34|2|2211.358..3073.781ms|2642.570ms|

The repeatedly slow29-operation submissions are not merely the first startup
sample. Nearby upload receipts show only102400 staged bytes/four writes with
reuse and no new allocation. Neither global lock contention nor repeated BO
allocation alone explains the sustained heavy phase. Final panel copies are a
secondary cost; the largest observed delays precede presentation.

Current source provides concrete targets for finer attribution:

- `A5XELTENativeQueue.inc` copies the full request job snapshot for each draw,
  cleans mapped image allocations once per group, and synchronously runs
  vertex/tiler followed by fragment work.
- `a5g3d_as1_run_job` cleans the entire job BO before START, polls completion,
  then flushes that BO to preserve GPU-written varying/polygon/heap data.
- Mapping/resource barriers commonly terminate groups before eight draws.

Next work should separate job-copy/cache-maintenance, mapping, descriptor
preparation and GPU polling durations, then reduce proven redundant work or
retain stable mappings. Cache operations protecting GPU-written intermediate
data must not simply be deleted. Scheduled/presentation overlap still needs a
real producer dependency and correct shared-CPU-data handoff; reinstating0243's
early Scheduled notification would reintroduce its unsafe ordering.

## Compiler, storage and process failures

The previously waiting fragment genuinely reaches STAGE PUBLISHED on the phone
with2208 native bytes. Its AIR translation reports406.850s wall time but about
10.13s CPU; the backend takes10.736s, both exit0. Later eight distinct fragment
waits and subsequent accepted stages/translator/backend executions are captured.
Only the first explicit publication receipt is logged; without corresponding
file reads, durable publication of every later request is not established.

Final eMMC counters show5187641344B read,368623616B written and zero errors;
max request92ms. I/O ownership is not attributed. Summed caller lock-wait
durations overlap and must not be treated as elapsed boot time. Cold compilation
and background I/O can explain some stalls, not all steady rendering cost.

Four process failures are recorded:

- driverkitd: one memory-limit SIGKILL.
- PosterBoard: one selectedLockPath assertion/SIGTRAP after the earlier empty
  pre-extension bootstrap repair completes. Selected-poster state is unresolved.
- assetsd: one SIGABRT with `assetsd requires TCCPhotosService access`.
- SpringBoard: one SIGTRAP. Captured strings concern keyboard-focus arbitration,
  but no exact fatal assertion/reason is recovered. A keyboard, TCC or GPU cause
  is not proven by proximity or heap strings.

Touch/HID81 and key/HID57 records are present. Completed GPU work, no captured
backboardd crash and the physical Clock repair are useful checkpoints; they do
not establish an entirely crash-free UI or acceptable animation performance.

Only aggregate findings are committed. Raw logs, device identifiers, request
identities, binaries and shader publications remain in private local evidence.
