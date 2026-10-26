/* SPDX-License-Identifier: MIT
 * Immutable contracts for private, locally translated QuartzCore programs.
 * Generated data is private. A registered shader is not a general Metal GPU.
 */
#ifndef A5_MALI_COMPILED_REGISTRY_H
#define A5_MALI_COMPILED_REGISTRY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
NS_ASSUME_NONNULL_BEGIN
#define A5_MALI_NULLABLE _Nullable
#else
#define A5_MALI_NULLABLE
#endif

enum { A5MaliStageVertex = 1, A5MaliStageFragment = 2 };
enum { A5MaliResourceBuffer = 1, A5MaliResourceTexture = 2,
       A5MaliResourceSampler = 3, A5MaliResourceInputAttachment = 4 };
enum { A5MaliResourceRead = 1, A5MaliResourceWrite = 2,
       A5MaliResourceStorage = 4, A5MaliResourceImmutableSampler = 8,
       A5MaliResourcePadUniformTail = 16 };
enum { A5MaliPushBindOffset = 1, A5MaliPushColorWriteRule = 2 };
enum { A5MaliProfileFixedViewport = 1, A5MaliProfileNearestSampler = 2,
       A5MaliProfileNormalizedSampler = 4, A5MaliProfileIndependentTargets = 8,
       A5MaliProfileSourceOverBlend = 16, A5MaliProfileNotExecutable = 32,
       A5MaliProfileCoverageAdd = 64, A5MaliProfileStrokeSourceOver = 128,
       A5MaliProfileInlineSourceOver = 256,
       /* Root-compiled stages, admitted by their reflected runtime ABI rather
        * than a constant/module fingerprint. These flags do not authorize a
        * new resource layout; the runtime validates it independently. */
       A5MaliProfileDynamicStages = 512,
       A5MaliProfileDynamicColorVarying = 1024,
       A5MaliProfileFramebufferFetch = 2048,
       A5MaliProfileFragmentPosition = 4096,
       /* Reflected ordered-fetch fragment has no native interpolants or
        * sampled resources. VS outputs still follow the validated QC ABI. */
       A5MaliProfileFragmentNoInputs = 8192,
       /* Native VS exports position, point-size and color; no UV varying. */
       A5MaliProfileVertexColorOnly = 16384,
       A5MaliProfileVertexTwoUV = 32768,
       A5MaliProfileFragmentTwoUV = 65536,
       /* Untextured FS reads only the exported float4 colour at native VAR0. */
       A5MaliProfileFragmentColorOnly = 131072,
       /* UV/procedural fragment with reflected interpolants but no sampled images. */
       A5MaliProfileFragmentNoTextures = 262144,
       A5MaliProfileScreenBlend = 524288,
       A5MaliProfileRenderState = 1048576,
       A5MaliProfileShaderBlend = 2097152,
       /* Reflected position/two-UV vertex program with no color input/export. */
       A5MaliProfileShaderAnisotropy = 8388608,
       A5MaliProfileVertexNoColor = 4194304 };
enum { A5MaliDynamicProfileID = 65536 };

typedef struct {
    const uint8_t *bytes;
    uint32_t byteCount, firstTag, workRegisters, tlsBytes, wlsBytes;
    const char *sha256;
} A5MaliCompiledShader;

typedef struct {
    const char *name;
    uint32_t dataType, byteCount;
    uint8_t raw[3];
} A5MaliCompiledFunctionConstant;

typedef struct {
    /* bindingIndex is the actual SPIR-V descriptor binding. Uniform words
     * use nativeIndex=bindingIndex+1. Storage records occupy stage UBO0 at
     * sysvalOffset, and contain GPUVA:u64, bytes:u32, reserved:u32. */
    uint32_t stage, kind, metalIndex, bindingIndex, nativeIndex;
    uint32_t flags, windowOffset, uniformBytes, sysvalOffset, pushOffset;
} A5MaliCompiledResource;

typedef struct {
    uint32_t stage, kind, metalIndex, offset, bytes, value;
} A5MaliCompiledPushField;

typedef struct {
    uint32_t index, format, offset, bufferIndex;
} A5MaliCompiledVertexAttribute;
typedef struct {
    uint32_t index, stride, stepFunction, stepRate;
} A5MaliCompiledVertexLayout;

typedef struct {
    uint32_t passID, logicalTarget;
    A5MaliCompiledShader vertex, fragment;
} A5MaliCompiledPass;

typedef struct {
    uint32_t writeMask, blendEnabled, rgbOperation, alphaOperation;
    uint32_t sourceRGB, destinationRGB, sourceAlpha, destinationAlpha;
} A5MaliCompiledAttachmentState;
typedef struct {
    A5MaliCompiledAttachmentState attachments[8];
} A5MaliCompiledAttachmentContract;

/* Immutable sampler states decoded by the AIR translator. Address modes use
 * the A5RuntimeSampler enum; these are not application Metal sampler slots. */
typedef struct {
    uint32_t nativeIndex, minFilter, magFilter, mipFilter;
    uint32_t sAddressMode, tAddressMode, rAddressMode, normalizedCoordinates;
    float lodMinClamp, lodMaxClamp;
} A5MaliCompiledSampler;

typedef struct A5MaliCompiledProfile {
    uint32_t profileID;
    const char *name, *vertexName, *fragmentName;
    uint32_t colorFormats[8]; /* actual Metal pixel-format numbers */
    uint32_t flags, viewportWidth, viewportHeight;
    const A5MaliCompiledPass *passes;
    uint32_t passCount;
    const A5MaliCompiledResource *resources;
    uint32_t resourceCount;
    const A5MaliCompiledPushField *pushFields;
    uint32_t pushFieldCount;
    const A5MaliCompiledVertexAttribute *attributes;
    uint32_t attributeCount;
    const A5MaliCompiledVertexLayout *layouts;
    uint32_t layoutCount;
    const A5MaliCompiledAttachmentContract *attachmentContracts;
    uint32_t attachmentContractCount;
    const A5MaliCompiledSampler *immutableSamplers;
    uint32_t immutableSamplerCount;
} A5MaliCompiledProfile;

/* Existing native blur route: the secondary declaration is inert only if
 * every authenticated attachment variant disables its writes and no pass or
 * input-attachment resource addresses it. Return its actual format; zero is
 * not permission to synthesize an attachment. No shader-name special cases. */
static inline uint32_t A5MaliCompiledInactiveColor1Format(const A5MaliCompiledProfile *p)
{
    if(!p || p->profileID<99 || p->profileID>108 || p->passCount!=1 ||
        !p->passes || p->passes[0].logicalTarget!=0 ||
        (p->colorFormats[1]!=80 && p->colorFormats[1]!=115) ||
        !p->attachmentContracts || !p->attachmentContractCount ||
        (p->resourceCount && !p->resources)) return 0;
    for(uint32_t i=0;i<p->attachmentContractCount;++i)
        if(p->attachmentContracts[i].attachments[1].writeMask ||
            p->attachmentContracts[i].attachments[1].blendEnabled) return 0;
    for(uint32_t i=0;i<p->resourceCount;++i)
        if(p->resources[i].kind==A5MaliResourceInputAttachment &&
            p->resources[i].metalIndex==1) return 0;
    return p->colorFormats[1];
}

/* IDs are stable wire identities, not array positions. Absent profiles are
 * unsupported. 100..108 blur, 200..208 misc native passes, 300..302 path
 * coverage remaps; 400..403 are host-only original MRT metadata.
 * A remapped test is never selected for an original MRT. */
#ifdef __cplusplus
extern "C" {
#endif
const A5MaliCompiledProfile * A5_MALI_NULLABLE A5MaliCompiledProfiles(size_t *count);
const A5MaliCompiledProfile * A5_MALI_NULLABLE A5MaliCompiledProfileForID(uint32_t profileID);
const A5MaliCompiledFunctionConstant * A5_MALI_NULLABLE
A5MaliCompiledConstantsForProfile(uint32_t profileID, size_t *count);
/* Exact vertex constants are separate from the fragment table above. */
const A5MaliCompiledFunctionConstant * A5_MALI_NULLABLE
A5MaliCompiledVertexConstantsForProfile(uint32_t profileID, size_t *count);

#ifdef __OBJC__
@class A5MaliMetalFunction;
/* Requires exact authenticated function instances from one library/device.
 * Constants, unsupported blend/depth/sample state and changed layouts fail. */
const A5MaliCompiledProfile * _Nullable A5MaliSelectCompiledProfile(
    MTLRenderPipelineDescriptor * _Nullable descriptor,
    NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
#endif
#ifdef __cplusplus
}
#endif
#undef A5_MALI_NULLABLE
#endif
