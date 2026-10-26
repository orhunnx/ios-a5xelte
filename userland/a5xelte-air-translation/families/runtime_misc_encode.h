/* SPDX-License-Identifier: MIT */
#ifndef A5_MALI_RUNTIME_MISC_ENCODE_H
#define A5_MALI_RUNTIME_MISC_ENCODE_H
#include "runtime_encode.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Commit-time copy of the application sampler descriptor. Values in these
 * enums describe the requested filtering/addressing, not a synthetic test
 * sampler. Unsupported combinations must fail before a native job is sent. */
enum { A5RuntimeSamplerNearest=0, A5RuntimeSamplerLinear=1 };
enum { A5RuntimeSamplerMipNone=0, A5RuntimeSamplerMipNearest=1,
       A5RuntimeSamplerMipLinear=2 };
enum { A5RuntimeSamplerClampEdge=0, A5RuntimeSamplerRepeat=1,
       A5RuntimeSamplerMirrorRepeat=2, A5RuntimeSamplerClampZero=3,
       A5RuntimeSamplerClampBorder=4 };
typedef struct {
    uint32_t valid;
    uint32_t minFilter, magFilter, mipFilter;
    uint32_t sAddressMode, tAddressMode, rAddressMode;
    uint32_t normalizedCoordinates, maxAnisotropy;
    uint32_t compareEnabled;
    float lodMinClamp, lodMaxClamp;
} A5RuntimeSampler;
/* One native pass for an original, authenticated misc pipeline. The caller
 * submits EVERY profile->passes entry in encoded order, retaining every
 * source/destination through its terminal fence. Configured but AIR-unwritten
 * attachment2 is not fabricated, cleared, or silently treated as an output.
 * The caller must independently implement the renderpass load/store actions. */
enum { A5RuntimeMipLevels=13 };
typedef struct { uint32_t levelCount; A5RuntimeImage levels[A5RuntimeMipLevels]; } A5RuntimeMipChain;
typedef struct {
    A5RuntimeDraw draw;
    uint32_t passIndex;
    float blendColor[4];
    A5RuntimeImage colorAttachments[8];
    A5RuntimeImage fragmentTextures[31];
    A5RuntimeSampler fragmentSamplers[31];
    A5RuntimeMipChain fragmentMips[31];
} A5RuntimeMiscDraw;
/* Large CPU-backed SSBOs must first be uploaded into a real mapped GPU buffer.
 * Copies of actual snapshots are bounded by the64KiB descriptor-owned arena;
 * insufficient space returns A5RuntimeBounds, never truncated/zeroed inputs.
 * Home's two constexpr samplers are the actual translated linear-clamp states.
 * Generic texture profile603 uses the snapshotted Sampler0 and accepts only
 * its separately compiled ClampToEdge specialization. */
int A5MaliDynamicRuntimeProfileSupported(const A5MaliCompiledProfile *);
/* Exact byte span of the consumed interleaved vertex records. Dynamic
 * layouts use the application's stride/offsets, including the last field;
 * legacy static profiles preserve their original 48-byte record contract. */
uint32_t A5MaliRuntimeVertexSpan(const A5MaliCompiledProfile *,uint32_t count);
/* Only generic/reflected layouts use the expanded, nonoverlapping output
 * planes. Older path/blur/home emitters retain their verified 256 bound. */
uint32_t A5MaliRuntimeMiscVertexLimit(const A5MaliCompiledProfile *);
/* CPU snapshot arena shrinks when large output planes borrow its tail. */
uint32_t A5MaliRuntimeMiscInlineCapacity(uint32_t vertexCount);
int A5MaliEncodeRuntimeMiscPass(const A5RuntimeMiscDraw *, void *, size_t);
#ifdef __cplusplus
}
#endif
#endif
