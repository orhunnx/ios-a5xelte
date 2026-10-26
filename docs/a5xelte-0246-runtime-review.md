# 0246 runtime: resource rejects absent, GPU execution remains expensive

Read-only TWRP SYSTEM capture: flush549,4442843total console bytes,4194304
recovered bytes/32965 decoded lines. The oldest248539bytes have been overwritten.
Early boot/installer evidence and earlier errors cannot be reconstructed from
this capture. The first recovered line is partial. Private raw logs and request
identities remain outside git.

## Rendering and compiler evidence

-62 captured command-buffer result records are Completed/error0. All123 captured
  timing records also report status4/error0. No sampled misc/sampler rejection,
  native-phase failure, kernel panic or SpringBoard/backboardd crash is present.
  This is not proof of success after bounded diagnostic budgets exhaust.
-758 sampled native groups allcomplete/status0:302size1,187size2,223size3 and
  46size4; last logged group48192.28native status receipts report status0/MMU0.
  All18666 AS0 fence receipts are complete/MMU0. Eight4096-point panel/source
  grids have zero RGB/alpha mismatch. They compare display storage to its source,
  not every compositor pixel to an independent image oracle.
-965 FB intervals cover5241452ms, including423zero-shown intervals. There are
  9333GPU panel copies,1CPUcopy,0GPUfallback. Reported peak7.5shown/s includes
  no-ops; reconstructed peak actual-copy rate is3.772/s. Long idle periods and
  uncontrolled workloads make this unsuitable for claiming a regression or
  improvement over0245. Reconstructed copy cost12.921ms remains similar.
-Resource rejection receipts from0245 are absent. Actual dynamic linking and
  native work continue, but there is no explicit successful six-level/aniso8
  binding receipt; absence of rejection alone does not prove that exact scene
  ran or that anisotropic pixels are correct.
-Nine new fragment identities have waiting receipts. A bounded355840B physical
  HFS read retrieves their project-only publications: all nine are genuine
  compilerABI2 successes with the shader-anisotropy marker and native/reflection
  hashes verified.35of36 allowlisted files exist; one request file was retired.
  Live dynamic fragment acceptance follows the waits. The automatic compiler
  does publish new code on the phone; cold waits can still interrupt animation.

## Phase measurements

Interleaved userland prefixes were separated before parsing integer fields;
otherwise lines ending directly at the next process prefix lose operations9/10/11.
Timings are sampled wall clocks. Nested costs must not be added together.

| Measurement | Samples | Median |
| --- | ---: | ---: |
| CB total execute wall time |123|94.195ms|
| Backend operations |123|78.188ms|
| Backend final drain |123|16.016ms|
| Native batch submit wall time per sampled session |123|67.497ms|
| Actual query transport per sampled session |123|0.798ms|
| Bulk upload per sampled session |123|0.413ms|
| AS1 mapping update |292|0.216ms|
| Once-per-batch output coherency |758|0.044ms|

Comparable backend totals:9operations14samples/90.145ms,10operations68samples/
94.151ms,11operations35samples/99.754ms. Heavy34..75operation samples reach
3.19..5.01seconds.0245's9operation median was84.668ms, so no speedup has been
established for that sampled class.

387 sampled native preparation receipts place most device time inside job
completion rather than CPU snapshot/image coherency/admission. Median descriptor
snapshot is about0.14..0.16ms, image store about0..0.114ms and admission about
0.004..0.007ms. Median job intervals are0.930ms for dynamic65536,13.0ms for602/
604,16.6ms for the single603/606 samples and3.236ms for clear. A dynamic outlier
reaches306.170ms. Samples are decimated, not an exhaustive profile distribution.

The current launcher runs vertex/tiler and fragment to terminal completion for
each draw, including within a userland batch. Its polling helper spins200us,
then sleeps1ms between checks. Job wall time therefore includes hardware work,
polling and scheduler wakeup; it does not measure GPU active cycles.13ms clusters
are not sufficient evidence to blame either GPU frequency or sleep overshoot.
The new userland transport_us=0 only means no additional non-query calls traversed
that wrapper in these sessions; direct bulk/submit calls have separate counters.

The next performance work should measure actual sleep/wakeup delay and combine
compatible draws within one render pass/tile list, preserving ordered fetch,
destination load/store and terminal ownership. Removing fences or cache stores
without dependencies would trade correctness for misleading throughput.

## Other crashes and the wallpaper report

The user reports that PosterBoard cannot offer wallpapers. The capture contains
one PosterBoard SIGTRAP with `Invalid condition not satisfying: selectedLockPath`.
The narrow bootstrap logs successful return from stock first-time setup before
this later invariant fails. This is not the old configuration-slot assertion.

A fresh254976B bounded read-only inventory confirms `/Library/Wallpaper`, nine
collections, seven Heritage Stripe stills, default identifier7400 and the five
414w-736h HEIC components associated with that default. The HEIC catalog entries
are HFS hardlinks: resolved real inode lengths are808440,677535,65125,608897 and
310057bytes; their headers contain the HEIC file type. They are not zero-byte or
proved-missing image files. Presence/header checks do not establish decoding or
complete provider registration.

The checked PosterBoard app is present. Its PlugIns and the checked framework
PlugIns path are absent; this alone does not establish where stock providers
should live. `/private/var/mobile/Library/PosterBoard` remains absent at that exact
path; an alternative app/group container has not been ruled out. Defaults,
provider registration, migration and selected-poster state must be traced before
copying assets or fabricating a selectedLockPath.

There is also one assetsd abort explicitly requiring TCCPhotosService access,
and two kbd SIGSEGVs at the same address with FAR0x10. These are separate issues;
the log does not establish that they cause the native GPU latency.44touch and
122key HID receipts are captured. Final storage counters:3.573GBread/277.871MBwrite,
zero errors. No device write or replacement image was performed in this readout.
