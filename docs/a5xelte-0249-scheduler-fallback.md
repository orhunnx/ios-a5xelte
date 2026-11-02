# 0249 — compiler no-progress fallback (runtime pending)

## Why

The 0248 readout shows four presented frames, then about an hour of
`swaps=0` snapshots. The shader service scans 126 old candidates with
`arrivals=0` and stops in old maintenance. 0248 only yields a stalled child
when a new authenticated function arrives, so a stalled old-maintenance child
with no new demand holds the service indefinitely.

## Change

- `userland/a5xelte-air-translation/ios/a5shader_compile.m`: keep the existing
  immediate yield on new demand, and add a fallback after 30 s without user CPU
  or output progress. The fallback kills and reaps only the worker's own
  compiler group, writes the existing retryable `deferred` status and returns
  to the scanner. No GPU work is cancelled and no shader success is synthesized.
- `xnu/patches/0020-stage-bearssl.sh` and `0026-stage-hfs.sh`: allow
  `MACHINE_CONFIG=A5XELTE` to stage the shared BearSSL and HFS sources. They
  previously staged only for `SWEET`, which makes a fresh A5XELTE build miss
  `bsd/sweet_hfs/core` and skip dependent patches.

## Packaging

- Worker: iOS ARM64, minimum 16.0, 4 KiB CodeDirectory pages. Raw size
  199,168 bytes, SHA-256
  `9a5ee40875fbdb42eea99aa076e0329cdbd13eb22c3c04bb3b89b7856cded1af`;
  zlib stream 62,750 bytes.
- The 0248 BOOT payload keeps its loader, DTBH, ADT, boot arguments and all
  other embedded files. Only the worker table fields, the worker blob and the
  Samsung SHA-1 header field change. BOOT size remains 26,720,272 bytes;
  SHA-256 `85d850fb52fb546ea08cfcf1a5b51575d086c2c266fe95b128b77b2bc2bfa9b7`.
- Written to BOOT p10 through TWRP, sync exit 0, full 26,720,272-byte readback
  matches the candidate SHA-256. No other partition was written.

## Runtime — 2026-11-02

A second 0249 boot rendered **42 frames at up to 7.5 FPS** before stopping.
The fallback itself fired twice:

```
YIELD request=0a3f… stage=metal2vulkan quiet=30.4 new_functions=0 fallback=1
DEFERRED request=0a3f… retryable=1 published=0
YIELD request=22d3… stage=metal2vulkan quiet=30.9 new_functions=0 fallback=1
DEFERRED request=22d3… retryable=1 published=0
```

The second request is `fixed_frag_lph_cph` (`22d301…`). Its
`metal2vulkan` child had only about 0.27 ms user CPU and 7.78 ms system CPU at
24 s, produced no log output, and was deferred at 30.9 s. After the deferral
backboardd kept reporting `phase=waiting` for the same request and no further
frame was presented. `PosterBoard` still traps on `selectedLockPath`.

So the scheduler no longer blocks the whole service, but the specific shader
translation still stalls; deferring it does not produce the publication the
compositor needs. No kernel panic occurred.

## Limits

- The underlying phone `metal2vulkan` stall and the missing publication remain
  unresolved. The 0248 and 0247 BOOT images remain available for rollback.
- This fallback does not repair the underlying phone compiler-child stall; it
  prevents one stalled child from holding the whole service.
- Fresh full-XNU reconstruction from the public patch series still needs the
  dependent patch order audited; 0249 was packaged by patching the existing
  0248 payload rather than relinking the kernel.
