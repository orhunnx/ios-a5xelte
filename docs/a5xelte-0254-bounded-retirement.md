# Bounded retirement and the 800 MHz preparation

## Bounded retirement

0253 disabled the old claim/lock/snapshot retirement path and reached 139
frames / 24.2 FPS with zero `a5shader-compile` crashes. 0254 keeps that path
disabled and adds a bounded archive cleanup:

- `a5BoundedArchiveCleanup()` opens `cacheRoot/completed-requests`, counts
  regular leaves, keeps the newest 64 and unlinks at most 32 per call.
- One directory `fsync` follows a non-empty cleanup; active request spools,
  status files and publications are untouched.
- It runs once at worker startup and every 128 scans.
- Worker: `A5_DISABLE_RETIREMENT=1`, raw 215,744 bytes, SHA-256
  `83be940e…`; BOOT 0254 SHA-256 `71b41010…`, p10 readback matched.

## 800 MHz preparation

The reference `clk-exynos7580-g3d.c` gives the PLL2551x entry:

```
800 MHz: m=400 p=13 s=0, MIF 825 MHz, interconnect 400 MHz
PMS = (400 << 12) | (13 << 4) | 0
lock = 13 * 200
MUX_G3D2 index 0 (PLL), core /1, peripheral /6 -> divider 0x50
BUCK4: 1,243,750 uV -> selector 0x87
```

The 0255 test kernel writes the PLL, waits for lock, selects PLL parent and
divider 0x50, and raises BUCK4 to 0x87. The MIF/interconnect votes are not yet
raised to 825/400 MHz.

**0255 measured:** `mux=00000000 div=00000050`, status 1 — the PLL parent and
800 MHz divider locked, no kernel panic. Best window was 8.3 FPS, below 400 MHz
(10.2 FPS loaded, 24.2 FPS light), consistent with the missing 825/400 MHz
memory/interconnect votes. 800 MHz is therefore not a win until those votes
are ported. 0254 remains the bounded-retirement fallback.

## Limits

The 800 MHz candidate is not validated. The 400 MHz 0254 image remains the
known-good fallback.
