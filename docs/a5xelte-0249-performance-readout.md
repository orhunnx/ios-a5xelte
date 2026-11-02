# 0249 performance readout — lock screen works, rendering is still slow

## What works

- The lock screen appears and touch input works.
- A 0249 boot rendered 42 frames in one window at 7.5 FPS. 0248 rendered two
  frames and stopped.

## Where the time goes

- The 30 s compiler fallback fired for two `fixed_frag_lph_cph` requests:
  `0a3f…` and `22d301…`. Each `metal2vulkan` child produced no output and
  was deferred. Backboardd then waited again on `22d301…`, so that request is
  still a visible stall, not a steady-state frame cost.
- The sampled GPU work contains one expensive native job:
  `poll_ns=189,085,884`, `sleep_ns=186,512,231`, 156 sleeps. The next sampled
  job was 9.27 ms. Most other samples are about 0.1 ms.
- Framebuffer copy is not the main cost: the 42-frame window reported
  `avg_copy_us=6329` (6.3 ms), `max_copy_us=14212`, and
  `avg_wait_us=25630` (25.6 ms). 42 frames in 5.55 s of that window is 7.5 FPS,
  about 133 ms per frame, consistent with the ~189 ms native job.
- GPU power/clock remains the inherited configuration: `mux=1`, `div=0x32`
  (TOP 400 MHz / 3, about 133 MHz inferred), BUCK4 readback 900 mV. No OPP
  change was made.
- The native transport still preloads and stores each draw separately; there
  is no compatible render-pass/tile-list merger.

## Order of work

1. Remove the two 30 s request stalls: capture the exact request inputs and
   either precompile/embed their publications or fix the phone translator hang.
2. Measure a verified GPU OPP step (for example 200 MHz at the Linux 987.5 mV
   point) with thermal and pixel checks; 133 MHz is the largest single
   steady-state lever but needs voltage/ASV validation.
3. Implement compatible-draw render-pass merging to remove repeated preload,
   store and terminal waits per draw.

## Limits

These are measurements from one 0249 boot. They do not establish sustained FPS,
thermal behavior or a value for a GPU clock change.
