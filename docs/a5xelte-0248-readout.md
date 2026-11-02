# 0248 readout — four frames, compiler service stalls (2026-11-02)

## Source

- Device: SM-A510F `a5xelte`, TWRP 3.3.0-0, recovery ADB.
- Read-only SYSTEM p20 ring, flush #365, 934,664 bytes recovered,
  10,507 lines, no overwrite.
- Parsed log SHA-256
  `9f8662646936c0e48067994f288b54bb15218a6f416c65b3aeaac0d0cb1abb51`;
  raw ring SHA-256
  `4ddc6a1b747627ac0bd9f63534af2946b546943bc0d2e6f3a68732493facbed8`.
- 0248 BOOT remains installed; no partition write.

## Boot

```
Darwin Kernel Version 22.6.0 ... orhuntx:xnu.obj/DEVELOPMENT_ARM64_A5XELTE
A5XELTE CPU: requested=4 selected=4 (limit=8)
A5XELTE G3D: BUCK4 readback 900000 uV
A5XELTE G3D: clock final mux=00000001 div=00000032
A5XELTE CPU: 4/4 CPUs initialized, SGI1 verified
```

Boot arguments remain four CPUs, 736 MiB, iPhone10,5/D211AP, native GPU,
`a5compiler=1`, `a5metal=1`, `a5native=1`.

## Runtime

- Only **4 presents / 2 shown frames**, all at about 5.3 s of FB elapsed time.
- 1,390 `A5XELTE FB` snapshots: 5 nonzero swap records, at most 2 shown
  frames, maximum reported 0.3 FPS. After the first seconds every snapshot is
  `swaps=0 shown=0 fps=0.0`.
- Last native G3D record is `profile=0` at line 3790; fences 9 and 10 complete
  cleanly at lines 3864–3866. No G3D error, MMU fault or kernel panic.
- The ring covers about one hour (365 flushes at 10 s) and contains no later
  frame. This is a stall, not a slow first frame.

## Compiler service

- `a5shader-compile` starts with `no_time_limit=1`.
- The eight reported scans all show:

```
users=1 candidates=126 deferred_old=126 handled=1 capped_users=1
maintenance=1 arrivals=0
```

- No `STAGE PUBLISHED`, `DEFERRED`, `RETRY`, `UNSUPPORTED` or
  `arriving-function` record appears in the retained log.
- `old-maintenance` tokens advance from `04845…` to `30fa…` (line 5852) and
  then stop. The process sampler later shows the worker waiting in
  `a5shader-compile`.

## Working hypothesis

Two 0248 paths combine:

1. The `a5RunTool` no-progress yield requires a newly arrived authenticated
   function (`arrived.count`). A stalled old-maintenance child with
   `arrivals=0` is therefore never yielded, and the worker does not return to
   the scan loop.
2. Presence of a result or status excludes a request from the arrival path in
   both `a5ScanRequests` and `a5DispatchArrivingFunctions`. An already
   retryable `deferred` status therefore demotes the request to one-per-scan
   old maintenance instead of prioritizing it.

The compositor submits four frames, waits for the next shader/pipeline, and
never resumes. This is consistent with the frozen screen; it is not yet proof
of the exact blocked request.

## Other recorded crashes

`PosterBoard` SIGTRAP (`selectedLockPath`), `assetsd` SIGABRT, and
`driverkitd` SIGKILL remain, as in 0246/0247. No kernel panic.

## Next

- Rollback candidate: `a5xelte-0247-boot.img`, SHA-256
  `c434317fc00e8ca5098e160e551d3de8fb8f0c261ea3c2bc4be66b6d1cf14d33`.
- 0249 candidate: unconditional no-progress deferral for the compiler child
  (bounded, e.g. 30 s) plus priority for retryable `deferred` requests, with
  host tests and a fresh BOOT package. Not implemented or installed here.
