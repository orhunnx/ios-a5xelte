# GPU OPP experiments — 200 MHz measured, 400 MHz installed

Reference OPP table: [exynos7580-a5xelte-gpu.dts](../../mainline/exynos7580-a5xelte-gpu.dts).

## 0251 — 200 MHz

- `a5g3d_power_cores` selected `div=0x31` (TOP 400 MHz / 2 = 200 MHz).
- BUCK4 selector was written as `0x5e` (987.5 mV nominal), but the boot log
  still reports `BUCK4 readback 900000 uV; enable unchanged`. The selector
  write/readback path did not change the measured rail voltage.
- One 0251 boot reached 19 frames in a window at 3.5 FPS, versus 2.9 FPS at
  133 MHz. No kernel panic. This is consistent with a partly clock-bound GPU,
  but the sample is small and the voltage remained 900 mV.
- The 0248/0251 boot used the 0249 worker without the embedded `0a3f`
  publication, so shader stalls are not comparable to 0250.

## 0252 — 400 MHz (installed, runtime pending)

- `div=0x30` (TOP 400 MHz / 1 = 400 MHz), BUCK4 selector `0x6e`
  (1.0875 V nominal).
- BOOT 25.827.344 bytes, SHA-256
  `18e5828b5276e8352426202cf475328eedec857082c54cbb411fd9dcd473bdf6`;
  p10 readback matches.
- The voltage readback issue above means this may actually run at 900 mV, which
  is well below the DT's 1.0875 V for the 440 MHz point. Treat 400 MHz as an
  experiment until the PMIC rail is independently measured.

## Limits

- The simple TOP-parent path tops out at 400 MHz. 668/734/800 MHz need the
  GPU PLL/parent sequence and memory/interconnect votes, not just a divider.
- [0227 patch](../xnu/patches/0227-a5xelte-gpu-400mhz-experiment.patch) records
  the 400 MHz experiment. It is not a validated production OPP.
