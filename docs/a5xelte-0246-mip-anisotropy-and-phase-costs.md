# 0246 — sampled mip chains, shader anisotropy and cost attribution

0245 accepted early compositor command buffers, then rejected a real 32x32 A8
source with six mip levels and a maxAnisotropy8 sampler. Later sampled buffers
ended Unsupported before execution. Its nine-operation command buffers still
cost about85ms; panel copying cost about13ms. This change repairs those resource
contracts and separates the remaining execution costs. It does not establish a
physical FPS improvement.

## Native resource and compiler changes

- Sampled2D bindings carry up to13 real logical mip layouts. Every level is
  resolved through the actual mapped surface or texture view. The released v4
  texture descriptor receives its own16-byte surface/stride record per level.
  Bounds, format, dimensions, target overlap and descriptor overlap are checked;
  buffer-backed linear textures remain single-level. No synthetic mip address
  or independent replacement storage is substituted.
- Min/mag and nearest/trilinear mip selection retain the public sampler state.
  Samplers accept maxAnisotropy1..16. A value above1 requires an authenticated
  fragment carrying the new lowering capability; old static shaders do not
  silently turn anisotropy into a single isotropic sample.
- Released Mesa26.2.4 explicitly marks T720 hardware anisotropy unsupported
  (`pan_model.c`, `MODEL_ANISO(NONE)`). Its v4 sampler has no anisotropy field.
  A new NIR pass therefore lowers eligible implicit/bias/gradient2D sampling
  into a bounded1..16-tap major-axis footprint integral in the original fragment.
  Runtime texture dimensions, sampler limit and LOD clamps control the GPU
  loop. The anisotropy1 branch retains original sampling; explicitLOD operations
  keep their explicitLOD semantics. This is a software approximation executed
  by the GPU, not a claim of hardware anisotropic sampler support.
- Fragment request compilerABI2 separates these programs from old ABI1 cache
  identities. The worker publishes the actual generation and the production
  loader requires matching identity and the lowering marker. VertexABI1 and
  existing receipts remain usable. Fifty captured fragment requests were
  genuinely translated/compiled on the Mac and loaded by the actual cache
  validator. The signed on-device worker and backend implement the same path.
- Expanded fragments can use a separate16KiB code range at0xc000..0xffff,
  beyond polygon state and before the tiler heap. The original8KiB range stays
  unchanged for smaller programs. Work-register/TLS/WLS/tag constraints remain.
  One real compiled fragment exceeds8KiB; the installer/cache/emitter limits are
  updated together. The typed compiled-directory ceiling rises from65 to129;
  canonical paths, ownership, immutable modes and exactly three files per
  publication remain required.

## Measurements

Userland grouping receipts now separate query, kernel transport, upload and
submission wall time. Kernel receipts separate descriptor snapshot, source image
coherency, admission, jobs and output coherency, plus mapping-update cost.
These are sampled wall-clock measurements and nested phases must not be added
as if independent. Terminal fence ordering, bounded upload reuse, shared-queue
arbitration and image coherency are retained.

## Verification and installation

- Structural descriptors verify all six mip pointers/strides, LOD5, actual
  anisotropy8 UBO state, capability gating, overlap rejection and relocation of
  an8992-byte fragment outside polygon/heap storage. These use synthetic code
  for descriptor checks and are not pixel tests.
- The real public Metal factory accepts a genuinely compiled3152-byte dynamic
  fragment with an8x sampler. The existing native upload/snapshot/descriptor/
  terminal-fence and failure tests pass with mocked kernel transport.
- Real Mac IOSurface tests cover mip subresources/copy generation and production
  resource dependency ordering. Cache ASan/UBSan tests additionally reject an
  old-generation receipt masquerading as generation2 and a missing/zero lowering
  marker. Device resource and alias tests pass.
- Actual kernel batch and separated CPU/GPU scratch-coherency harnesses pass.
  The three-file incremental patch applies without fuzz and matches the donor.
  Full XNU make exits0 after the usual dsymutil sandbox retry. Signed provider,
  worker and backend have verified4KiB signature pages. The actual553-file
  installer stream/policy preflight passes under ASan/UBSan with no filesystem
  writes; final linked kernel segments and every embedded file/CRC are checked.
- The payload contains89 compiled stages, including50 new generation2 fragments.
  Only provider, compiler worker and compiler backend differ among the previous
  files. Selected stock app bytes/metadata and the complete PosterBoard resource
  seal remain checked against the prior artifacts.

BOOT26718224B, kernel26051920B. BOOT SHA256:
`628ab24fe075b7a96f06ba9646d79a4ed9ae1897ded84368e94939140b567878`.
The loader/DTBH and previous boot arguments remain exact: four CPUs,736MiB,
iPhone10,5/D211AP,32-sector I/O, native GPU, touch enabled, full-frame presentation
without CPU comparison. The private pixel suite remains disabled.

Guarded recovery/model/TWRP/canonicalBOOTp10/capacity checks pass. The offset-zero
write acknowledges all26718224bytes; sync exits0 and reboot is requested. No
BOOT backup, post-write readback/hash or wholeUSERDATA transfer was performed.
Physical mip/aniso pixels, live compositor acceptance and performance are pending.
Next inspect Clock correctness, scrolling and stopwatch cadence, then read the
new resource rejection, phase-cost and command-buffer results in TWRP.
