# 0245 readout: no demonstrated speed gain; rejected mip/anisotropic draws

The user reports similar UI speed and returned to TWRP. Read-only SYSTEM
flush106 recovers1290219 raw bytes/11533 decoded lines without ring overwrite.
Framebuffer sample windows span1087664ms (about18min), versus76min in0244.
These are different uncontrolled workloads, not a controlled FPS regression test.
No new image or device write was performed during this review.

## Completion, presentation and timings

1742 GPU and3 CPU copies,1 GPU fallback,3493 shown records including1743
self/missing-source records. Peak actual copy rate5.116/s; reported10.2/s
includes no-ops and is not rendered FPS. Reconstructed presentation cost is
12.836ms/copy, close to0244's12.858ms. Pending age is26.239ms. Eight4096-point
panel/source grids have zero RGB/alpha mismatches.

All89 captured native groups complete/status0, last sampled group5184. Group
sizes:29x1,35x2,2x3,3x4,3x5,4x6,11x7,2x8. The cache/group optimization is
exercised:29 sampled session receipts total273 cached queries,174 query
barriers,0 mutation/epoch barriers and3 capacity flushes, all result0. These
sampled sums are not total runtime counts. Retained upload reuse continues.

All32 native status receipts and3488 captured fence receipts complete with
MMU0. There is no recorded kernel panic or backboardd/SpringBoard/PosterBoard
crash; one driverkitd memory-limit SIGKILL remains. Absence of the previous
PosterBoard assertion in this capture is not proof its selected state is fixed.

The first65 captured public commit-result receipts are Completed/error0, but
**later independent timing receipts expose failures**:28 Completed/error0 and
7 Error/`e00002c7` (Unsupported). Reporting only the exhausted early success
budget would miss these failures. Native completion does not mean every Metal
command buffer reached the GPU.

| Comparable sampled backend work |0244|0245|
| --- | ---: | ---: |
|9 operations, median total|84.694ms (9 samples)|84.668ms (13 samples)|
|29 operations, total|1346.946..1364.660ms (8)|1354.547ms (1)|
|Backend lock median|11us|10us|
|Final panel copy|12.858ms|12.836ms|

Nine operations are only a workload-size grouping, not proof of identical
descriptors. Nonetheless there is no measured improvement of that order of
latency. All29 captured backend executions succeed; errors discussed below
reject during public encoding and have execute_us0.

138 new native-cost receipts prove the GPU-owned continuation is running:

| Native phase |Samples|Median store|Median poll/idle|Median header reconciliation|
| --- | ---: | ---: | ---: | ---: |
|vertex/tiler|66|116.654us|130.346us|11.423us|
|fragment continuation|65|0.115us (0 bytes)|534.884us|12.038us|
|clear|7|93.961us|167.730us|12.269us|

Vertex stores262144B and reconciles64..96B; continuation stores0B and
reconciles32B. This removes real redundant work, but its measured CPU cache
cost is too small to establish a large overall speedup. Polling maxima include
188.835ms fragment outliers. Sampling every256 jobs can bias which workloads
and stages are captured; these medians do not prove GPU work is globally cheap.
Polling wall time also includes scheduling/MMIO/idle checks. Remaining operation
time includes image stores/reconciliation, mappings/MMU changes, packet copies,
descriptor preparation, intermediate drains and unobserved GPU jobs; exact
dominant subphase remains unattributed. Nine admission samples recover in
2.464..12.031ms, without mapping failure or admission timeout.

## Concrete functional blockers

At the first captured failing indexed draw, backboardd binds a32x32 A8 texture
(format1,2D,samples1,shader-read,real surface) with6 mip levels at fragment
texture slot3. It requests a normalized clamp sampler with linear min/mag and
mip filtering, maxAnisotropy8. The compiled fragment is accepted, but:

- `A5MaliMetalDeviceResources.m` rejects maxAnisotropy other than1, returning no
  usable sampler.64 bounded anisotropy rejection receipts are captured, plus
  one independent unnormalized-coordinate rejection.
- `A5MaliMetalAPI.m` rejects sampled textures whose mipmapLevelCount differs
  from1 at the misc/dynamic resource gate.48 bounded source-subresource
  rejections explicitly describe this32x32/6-level texture.
-32 indexed-draw rejection receipts report pipeline-or-resource-contract.
  The first error is Unsupported. Later sampled command buffers with98 draws
  end status5/error e00002c7 and execute_us0, so none of their queued rendering
  is submitted by that commit. The capture does not establish the total number
  of failed buffers after diagnostic budgets exhaust.

These are separate encoding support gaps, not GPU fence failures or proof that
0245 introduced them;0244 exercised different scenes and logged none of these
rejections. Mip storage/copy generation exists, but native sampled descriptor
and sampler support still reject this real usage. Next functional work needs
real mip-level address/layout/LOD and anisotropic sampler encoding, backed by
pixel tests. Removing the gates or pretending level0/anisotropy1 satisfies the
original request would hide an unsupported contract.

## Compiler, storage, input and next performance measurement

Four distinct fragment waits are captured. One explicit phone publication
contains2432B; later execution/validation/backend activity and stage acceptance
continue. At the last wait, the backend is observed and an accepted1168B stage
follows. Persistent files for every request were not read, so not every late
publication is independently verified. Final eMMC:2846732800B read,
123752448B written, errors0; maximum request69ms. Storage ownership remains
unattributed.19 touch/HID and10 key/HID records are present; key queue tails
advance without full-queue reports.

Keep0245's terminal ordering and verified ownership reduction. For performance,
measure the per-operation query/mapping/MMU, image coherency, upload/emitter and
intermediate drain times; a sub-millisecond cache reduction cannot alone fix
the observed85ms and1.35s submissions. Address rejected sampling contracts
separately from successful-frame latency. Raw logs, device identity, request
keys and shaders stay private; only aggregate findings are committed.
