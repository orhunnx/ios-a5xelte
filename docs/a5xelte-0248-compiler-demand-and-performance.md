# 0248 — ready stages, compiler demand scheduling and performance priorities

0247 captures a translator child still running after301.3s, with no output and
almost no user CPU progress. Backboardd subsequently waits for a different
function, but the synchronous child wait prevents the worker from scanning that
new demand. Both captured original functions genuinely compile on the Mac.
0248 embeds their complete3440/4544-byte native publications and changes worker
scheduling. It does not claim to fix the underlying phone child stall or the
steady rendering cost.

## Implementation

`ios/a5shader_compile.m` snapshots other authenticated runnable function keys
before launching its own compiler process group. Once per second it accounts
group user CPU and output growth. More than1ms of new user CPU or changed output
resets the quiet timer. If there has been at least10s without either kind of
progress, output is empty, and a new authenticated function has arrived, it
kills only its own compiler group, reaps its exact direct child and checks the
group has emptied. An internal exception then returns control to the scanner.
Progressing tools still have no elapsed compilation limit. No GPU work is
cancelled and no shader success is synthesized.

`ios/a5shader_requests.inc.m` bounds the demand scan, uses the existing protected
UID/function lanes and safe readers, and verifies canonical request identity,
owner, type, source, GPU and compiler generation. Hash-mismatched and symlink
leaves cannot trigger a yield. Presence of a result/status is only a scheduling
hint; it does not replace publication validation. The yielded private work tree
is removed and a root-private retryable `deferred` status is written. New
function demand is dispatched immediately after yielding. The old request can
retry in a later maintenance turn; deferral never becomes public Unsupported,
Failed, a native publication or permission to retire the pending request.

`ios/a5shader_retirement.inc.m` accepts genuine ABI2 native code up to16KiB with
the required anisotropy-lowering marker; ABI1 and known pipeline records retain
their8KiB bounds. Exact members, identities, hashes and file protections remain
required. The former universal8KiB retirement bound could retain an otherwise
valid8992-byte ABI2 publication indefinitely.

## Validation and installed artifact

- Actual worker integration substitutes a real OS sleep only in the test build.
  Invalid/hash-mismatched and symlink arrivals do not interrupt it. A valid new
  request causes verified child reaping and Deferred; the new request genuinely
  translates and compiles, then the old request retries through the real tools.
  Both publications match independently built reference bytes and pass the
  production cache loader under ASan/UBSan. The substitution hook is excluded
  from the signed device worker.
- Real OS child isolation, limits, descendants and invalid tool-path diagnostics
  pass. Late-arrival and quota boundary regressions pass. Retirement tests cover
  300 records, bounded archive, preserved64 pending entries, corrupt/unsafe
  files, claim races and a genuine8992-byte ABI2 publication. The retirement
  fixture was corrected to submit a typed pipeline into the pipeline lane and
  expect the existing retryable Busy quota result; producer quota is unchanged.
- Signed iOS A53 worker with4KiB signature pages; full XNU make exits0. Actual
  kernel installer preflight under ASan/UBSan passes all559 files without
  filesystem writes. Final Mach-O segments, embedded file bytes/CRCs,91 stages,
  270 selected original app files and metadata, and the complete PosterBoard
  resource seal are verified. Only the worker changes among old payload files;
  six new files hold the two complete immutable publications. Provider/backend,
  existing shader bytes and functional kernel code remain0247.

BOOT26720272B, kernel26052544B. BOOT SHA256:
`5f9a2b8fa75e7f178eacde3eb023cf1ce2abf3ed4fdeac74434408f4bbb21645`.
Prior loader/DTBH/arguments remain: four CPUs,736MiB,iPhone10,5/D211AP,
native GPU,32-sector storage and full-frame presentation without comparison.
Guarded recovery/model/TWRP/canonicalBOOTp10/capacity checks pass; offset-zero
write acknowledges all26720272bytes, sync exits0 and reboot is requested.
No BOOT backup, post-write readback/hash or wholeUSERDATA transfer is performed.
Physical compiler scheduling, shader consumption, graphics correctness and FPS
remain pending. PosterBoard selectedLockPath is not repaired by this build.

## Why the initial GPU path can be slower than CPU compositing

The recovered0247 timings place much more wall time in native jobs than resource
upload or final presentation. Two34-operation groups take about3.19s; the final
screen copy averages12.305ms. There is no matched CPU-versus-GPU benchmark, but
the current implementation has a concrete architectural cost consistent with
the user's observation.

The eight-draw native batch amortizes transport, mappings and coherency. It
still executes a separate vertex/tiler and final fragment sequence for each
draw. `families/runtime_misc_encode.c` invokes `a5_runtime_preload` for each
draw; `families/runtime_preload.h` restores the previous attachment into tile
storage before the application draw. Each final fragment stage stores it again.
Increasing transport batch capacity alone cannot remove those repeated
attachment loads/stores or intermediate terminal waits.

Pinned release Mesa26.2.4 uses a different lifetime: `pan_job.c` submits a
framebuffer batch, while `pan_jm.c` emits the final fragment job for that batch.
Multiple compatible draws can share the tile working set. Arm documents that
keeping the working set in tile memory avoids external-memory traffic for
within-pass blending/depth. Applying that model is an inference about our next
optimization, not a measured speedup yet.
[Arm tile renderer architecture](https://arm-software.github.io/magog/docs/03_mobile_gpus/03_tile_based_renderers/).

### 1. Merge compatible draws into a real render pass

Preserve a shared attachment/format/sample count, AS1 resource epoch and immutable
input lifetime; chain VS/tiler jobs with distinct draw descriptors, uniforms,
varyings and shader addresses. Preload once per pass (or clear according to the
actual load action) and run one final fragment stage. Preserve ordered blending
and framebuffer fetch. Texture feedback, aliases, target changes and barriers
must split the pass. The current256KiB scratch cannot simply contain eight
arbitrarily large copied job images: pool bounds and shared tiler storage need
an explicit layout. Completion remains a genuine terminal pass fence, with
correct dependency propagation; the unsafe0243 early presentation behavior must
not return. Validate overlapping/scissored/fetch/blended draws and untouched
tiles against independent expected pixels, then compare actual pass counts and
matched frame times. **Not implemented in0248.**

### 2. Verify and select a valid GPU clock/voltage operating point

The current XNU setup assumes an inherited TOP400MHz parent and divide-by-three
core path; mux1/divider0x32 is captured. This implies nominal133MHz if that parent
assumption is correct; it is not a measured clock rate. PMIC readback reports
900mV. The local Exynos7580 Linux reference OPP table instead starts with
987500uV nominal at133/160/200MHz (ASV-dependent variants differ). Its clock code
uses the TOP path for133/200MHz, PLL sequencing for higher points, peripheral
clock limits and additional memory/interconnect votes at higher rates.

The clock-parent assumption, actual ASV group, voltage requirements, transitions
and thermal behavior must be verified before raising frequency. Do not copy a
development driver's unverified quirks or simply change a divider at900mV.
Measure actual rate/cycles and CPU/thermal state along with repeated workloads;
Mesa's benchmark guidance explicitly calls out clock state and CPU bottlenecks.
[Mesa Panfrost benchmarking](https://docs.mesa3d.org/drivers/panfrost/benchmarking.html),
[kernel Panfrost profiling](https://origin.kernel.org/doc/html/latest/gpu/panfrost.html).
**No voltage/frequency change in0248.**

### 3. Remove the final copy after the larger render cost

Direct DECON scanout of a completed compatible render target could remove the
roughly12ms final copy. This needs a suitable physical layout, pitch, buffer
ownership and real producer completion. Current IOSurface row4352 differs from
the legacy framebuffer row4320; assigning an arbitrary IOSurface address is not
a valid implementation. Use double/triple buffering with terminal ownership.
Mali renders, while a separate display controller scans the result out.
[Mesa Panfrost overview](https://docs.mesa3d.org/drivers/panfrost.html).
Existing fragment bounds already use scissor tiles, so adding scissor handling
is not a new optimization. Do not reintroduce full-frame CPU comparison.

Persistent private texture tiling may later improve sampling locality; keep
public linear aliases correct and avoid a full CPU retile every frame. Compiler
fairness and durable stages remove cold blocking, but cannot by themselves fix
steady seconds-long render groups. GPU-active-cycle measurements are still
needed to distinguish actual shader/memory work from all launcher wall time.
