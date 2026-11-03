# MIF 825 MHz port attempt — 0257

The downstream `clk-exynos7580.c` `table_mem0` entry for 825 MHz is
`p=13, m=825, s=1`. 0257 mapped CMU_MIF at `0x10430000` and programmed the
MIF5 path directly:

- PLL `0x120`: `pms=(825<<12)|(13<<4)|1`, enable/lock;
- `0x214[8]` MIF5 select, `0x204[8]` enable, `0x20c[24]` /2 cleared;
- divider `0x604[14:12]=0` (/1).

Result: PLL locked (`pll=a03390d1`, m=825 p=13 s=1) and the GPU stayed at
668 MHz (`div=0x40`), but the **PMIC HSI2C timed out**:

```
A5XELTE TOUCH: PMIC HSI2C timeout rx=0 done=1/1 irq=0x42 state=0 fifo=0x1000100
A5XELTE TOUCH: PMIC identity/control read failed
```

Touch and PMIC access died; FPS stayed 10.2, the same as 400 MHz. p10 was
restored to 0254 (400 MHz, touch working).

The direct MIF5 write is not a safe port: HSI2C/PMIC share this CMU and the
divider/mux sequence needs the downstream CCF/DVFS ordering, not a single
PLL+divider write. Do not repeat this write without the full MIF DVFS sequence.

## 0259 — MIF core /2, touch restored

0258 used MIF core /1 (825 MHz bus) and hung before the console. 0259 keeps
the MIF PLL at 825 MHz but divides the bus by 2 (412.5 MHz) and the fix-100
HSI2C3/PMIC branch by 8:

```
A5XELTE G3D: MIF 825 pll=a03390d1 mux=00000100 div=00007711
A5XELTE G3D: clock final mux=00000000 div=00000040
```

Touch works again (HID touch events, no PMIC HSI2C timeout). GPU 668 MHz
reached 6.8 FPS, still below 400 MHz (10.2). The 825 MHz MIF bus itself is not
usable (core /1 hangs); only the /2 bus is stable, so 668/800 remain
memory-starved. p10 was restored to 0254 (400 MHz).

