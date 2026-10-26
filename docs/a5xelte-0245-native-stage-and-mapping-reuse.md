# 0245: GPU-owned intermediate data and stable-mapping groups

0244 repaired the physical Clock corruption, but backend operation processing
remained much slower than dispatch/locks or final presentation. This follow-up
reduces two concrete repeated operations while preserving terminal presentation
ordering. Host checks and a completed build do not establish phone FPS gains.

## Keep native intermediate data on the GPU

Previously every native vertex/tiler and fragment launch stored the entire
256KiB job BO before START and reconciled it afterward. The vertex pass flushed
GPU-written varyings/heap into CPU aliases, solely so the next full CPU store
would not overwrite them with stale bytes. Native execution does not otherwise
read or modify that scratch between these two stages.

The new native path stores the full immutable snapshot once before the first
job. After each real terminal job it reconciles only the32-byte completion
headers that the CPU actually inspects (including linked tiler/preload headers).
Fragment execution does not store the CPU job alias again. The next draw still
replaces every byte of the job image before its full store. Typed jobs retain
their original complete-image store/flush contract. Image input stores, output
reconciliation, real header/fault checks, fences and quarantine remain.

For a native draw this removes one256KiB CPU store and replaces two256KiB
reconciliations with96..128 header bytes. It does not remove the immutable
256KiB snapshot copy or claim that all cache work was redundant. Sampled native
cost receipts separate store, polling/idle and header reconciliation wall
durations; polling includes scheduling/MMIO overhead, not pure GPU timestamps.

## Reuse existing physical mappings across logical resource sets

The previous query cache matched the entire logical token array byte-for-byte.
Even a target-only clear after a textured draw forced a pending group to drain,
despite every physical mapping already existing. The query cache now projects
subsets/reorderings of its validated resident set, returning the original
per-token GPU VA/span and unchanged epoch, with zero spans for absent entries.
The complete cached set is retained after a subset query.

Groups may now contain different logical resource arrays under the same nonzero
mapping epoch. Before any START the kernel independently validates every item's
live generations, mappings, access masks, descriptor topology and epoch, and
collects the actual physical read/write union for group coherency. Changed
epochs and invalid/stale tokens reject before dispatch. Unknown query resources
still drain pending work before a query may change PTEs. Any ordinary transport
mutation still drains and invalidates the cache. No new address-space ownership,
public ABI size, mapping-slot count or untrusted shader capability is added.

Counters record cached queries, query/mutation/epoch barriers and capacity
flushes, allowing the next runtime to show whether useful groups actually grow.
The eight-item bound and all-item preflight remain. The signed provider and
paired kernel patch must be installed together.

## Validation and image

- Actual AS1 launcher under ASan/UBSan, with separate noncoherent CPU/GPU images:
  GPU-generated scratch stays invisible on the CPU yet reaches fragment intact;
  a fresh draw replaces old scratch; native clear and optional preload headers
  reconcile correctly; typed jobs retain full coherency. Store/flush failures,
  timeout and hardware fault never advertise completion.
- Actual native transport/session, upload arenas and Objective-C command buffer
  under ASan/UBSan:8+3 and8+1 groups, resource subset/reorder VA preservation,
  retained full query set, unknown-resource/mutation barriers, abort, immutable
  uploads, pool pressure and malformed/fault quarantine. Updated one stale
  four-item command-buffer expectation to the existing eight-item capacity.
- Actual kernel preflight/group dispatch test: differing live token sets and
  reordered/subset items work, stale generations/epochs fail before START;
  ordered real fences, image coherency and poisoning tests pass.
- Existing native603 public factory/emitter snapshot test and actual
  IOSurface/no-copy blocked-completion dependency integration pass with
  ASan/UBSan. No Scheduled/submitted/alias access before the terminal producer
  fence;0243's unsafe early notification is not restored. Host transport tests
  do not prove physical GPU pixels.
- Four-file incremental patch applies strictly and matches the staged source.
  Signed iOS16/A53 provider/probe have4096-byte CodeDirectory pages. Full XNU
  make exits0 after retrying dsymutil outside its /dev/fd sandbox restriction.
  Actual403-file installer stream/policy preflight passes without filesystem
  writes. Final linked segments and all embedded file bytes/CRCs are checked.

BOOT26118160B, kernel25451112B, provider1018256B. BOOT SHA256:
`8a6d96deab2671d26a7ed60997382d4f93442df8136afc34b9c0e7e6f07cf9a2`.
Same loader/DTBH/boot settings, four CPUs/736MiB, iPhone10,5/D211AP,
32-sector I/O, comparison disabled and39 compiled stages. Only the provider
file changes among the403 embedded files; selected apps and PosterBoard seal
remain intact. PosterBoard selectedLockPath and the unresolved SpringBoard
trap are not claimed repaired by this optimization.

Guarded recovery/model/TWRP/canonicalBOOTp10/capacity checks pass. The offset-zero
write acknowledges all26118160 bytes, sync exits0 and reboot is requested.
No BOOT backup, readback/hash comparison or whole USERDATA transfer was performed.
Physical performance remains unverified. Next compare Clock correctness and
scroll/stopwatch responsiveness, then read actual groups, native costs,
fallbacks and panel-copy counts in TWRP.
