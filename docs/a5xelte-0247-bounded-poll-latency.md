# 0247 — reduce short-job sleep latency while retaining terminal fences

0246 native submission wall time is much larger than upload or mapping time.
The launcher previously switched from ten-microsecond polling to IOSleep(1)
after200us. A requested1ms sleep can include additional scheduler wakeup time;
0246's job measurements do not distinguish this from active GPU work.

Patch0226 changes the shared AS0/AS1 polling helper:

- Poll in10us steps for up to2ms of accounted pause time before yielding.
  This lets short jobs finish without entering the scheduler sleep path.
  Long jobs still use IOSleep(1), rather than spinning for the full timeout.
  More busy polling may consume extra CPU; a physical throughput improvement
  has not been established.
- Each pause records actual elapsed time. Timeout accounting charges at least
  the requested pause and, if longer, the measured rounded-up duration, bounded
  by the remaining budget. Requested timeout values remain unchanged. This
  prevents repeated long wakeups from being charged as only1ms; it is not a
  hard absolute deadline that excludes all MMIO/scheduling overhead.
- Both launchers take a final terminal/fault RAW sample after the last pause.
  A real completion at the budget boundary is no longer missed solely because
  the loop condition expired before that sample.
- Sampled native and typed-presentation receipts report spin/sleep wall time
  and counts, plus the2ms policy. Native total polling and AS0 polling windows
  include slot-idle checks, but exclude output/header reconciliation.

No early completion, idle-slot relaxation, cache-operation removal or uncertain
resource reuse is introduced. Fault, timeout and ownership/quarantine behavior
remain required. There is no GPU frequency change, IRQ-driven completion or
multi-draw render-pass/tile-list merger in this change.

## Validation

The actual AS1 function and shared helper pass ASan/UBSan tests for50us and800us
completion, long-job yielding, normal/coarse-wakeup timeout accounting, terminal
fault, preflight busy, invalid headers and incomplete linked headers. With a
simulated12ms scheduler sleep, the same800us completion is observed at12.2ms
under the old200us threshold and at800us under the new2ms threshold. This is a
mock timing example, not a measurement of this phone. The exact timeout-boundary
completion passes. PosterBoard authorization/boot-gate regressions also pass.

Actual separated CPU/GPU memory tests retain scratch ownership, one store for
native continuation, typed full reconciliation and failure quarantine. Actual
kernel batch preflight/order/coherency tests pass. The three-file patch applies
without fuzz and matches the staged donor. Full XNU make exits0; the linked kernel
contains the new policy/measurement markers. All final segments and553 embedded
files/CRCs are checked. Provider, compiler,89 staged shaders, selected app bytes,
PosterBoard seal and the entire embedded payload are exact0246 bytes. Earlier
installer/cache/signature results apply to those unchanged payloads; they were
not rerun as if new functional changes.

BOOT26720272B, kernel26052112B. BOOT SHA256:
`c434317fc00e8ca5098e160e551d3de8fb8f0c261ea3c2bc4be66b6d1cf14d33`.
Prior loader/DTBH/arguments are retained: four CPUs,736MiB,iPhone10,5/D211AP,
native GPU,32-sector storage and full-frame presentation without CPU comparison.

Guarded recovery/model/TWRP/canonicalBOOTp10/capacity checks pass. Offset-zero
writing acknowledges all26720272bytes; sync exits0 and reboot is requested.
No BOOT backup, post-write readback/hash or wholeUSERDATA transfer was performed.
Physical latency, FPS, CPU cost and graphics correctness remain pending. The
user was asked to compare scrolling/stopwatch behavior and return to TWRP for
spin/sleep, submission, timeout and panel-copy measurements. PosterBoard's
selectedLockPath state issue remains outside this polling change.
