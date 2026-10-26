/* SPDX-License-Identifier: MIT
 * Real dynamic misc-pass emitter. Code/constants are supplied by authenticated
 * profiles; vertices, uniforms, storage buffers and images are actual bindings.
 */
#define PAN_ARCH 4
#include <stdint.h>
#include "runtime_misc_encode.h"
#include "../../a5mali-metal/A5MaliRenderState.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "genxml/v4_pack.h"
#include "runtime_preload.h"

enum { SIZE=0x40000, W=32,H=32, FB=0x300,VS_RSD=0x500,FS_RSD=0x540,
 TEX0=0x600,TEX1=0x640,TEX_TABLE=0x680,SAMPLERS=0x6a0,
 VS_UBOS=0x700,FS_UBOS=0x740,ATTRS=0x800,ATTR_BUFS=0x900,
 VS_VARY=0xa00,VS_VARY_BUFS=0xa80,FS_VARY=0xc00,FS_VARY_BUFS=0xc80,
 VIEWPORT=0xe00,VS_SYS=0x1000,FS_SYS=0x1400,
 SSBO_VERT=0x2000,ORDINARY=0x3000,POS=0x30000,PSIZ=0x31000,
 VARY_DATA=0x32000,VS_CODE=0x6000,FS_CODE=0x8000,BIG_FS_CODE=0xc000,POLY=0xa000,POLY_BODY=0xa200,
 DYNAMIC_TEX=0x4000,DYNAMIC_TEX_TABLE=0x4100,DYNAMIC_SAMPLERS=0x4140,
 MIP_TEX=0x4200,MIP_TEX_STRIDE=256,
 HEAP=0x10000,HEAP_SIZE=0x10000,SOURCE=0x20000,LUT=0x22000,
 DEST=0x24000,GUARDS=0x28000 };
enum { RG_SWIZZLE=MALI_CHANNEL_R|(MALI_CHANNEL_G<<3)|(MALI_CHANNEL_0<<6)|(MALI_CHANNEL_1<<9),
 A_SWIZZLE=MALI_CHANNEL_0|(MALI_CHANNEL_0<<3)|(MALI_CHANNEL_0<<6)|(MALI_CHANNEL_R<<9),
 R_SWIZZLE=MALI_CHANNEL_R|(MALI_CHANNEL_0<<3)|(MALI_CHANNEL_0<<6)|(MALI_CHANNEL_1<<9) };
enum { ARENA=0x20000,ARENA_END=0x30000 };
/* Preserve the device-tested small layout byte-for-byte. Larger generic
 * draws reserve a full 16-byte position, 2-byte point size, two 8-byte UVs
 * and one 16-byte colour for every vertex. No output plane aliases another
 * plane, the bounded input arena, or the fixed 0x40000-byte job allocation. */
/* Pack outputs from the real count, aligned to64 bytes. Above1280 vertices
 * borrow16KiB from the input arena. All five planes for1600 vertices then
 * fit in80KiB, without changing the kernel's fixed256KiB job ABI. */
enum { LARGE_POS=0x2c000 };
_Static_assert(LARGE_POS+50*A5RuntimeMiscMaxVertices<=SIZE,"large dual UV");
static unsigned aligned_plane(unsigned size){return (size+63u)&~63u;}
static unsigned position_offset(const A5RuntimeDraw*r){return r->vertexCount>A5RuntimeMiscCompactVertices?LARGE_POS:POS;}
static unsigned point_size_offset(const A5RuntimeDraw*r){return r->vertexCount>A5RuntimeMaxVertices?position_offset(r)+aligned_plane(r->vertexCount*16):PSIZ;}
static unsigned varying_offset(const A5RuntimeDraw*r){return r->vertexCount>A5RuntimeMaxVertices?point_size_offset(r)+aligned_plane(r->vertexCount*2):VARY_DATA;}
static unsigned varying_step(const A5RuntimeDraw*r){return r->vertexCount>A5RuntimeMaxVertices?aligned_plane(r->vertexCount*8):0x1000;}
uint32_t A5MaliRuntimeMiscInlineCapacity(uint32_t count){return (count>A5RuntimeMiscCompactVertices?LARGE_POS:ARENA_END)-ARENA;}
_Static_assert(MALI_ATTRIBUTE_BUFFER_LENGTH == 16, "v4 attribute table stride");
/* ATTRIBUTE buffer_index counts 16-byte descriptors, not 32-byte allocations.
 * Keep the deliberately padded special InstanceID at physical slot2. */
static void u32(uint8_t*d,unsigned o,uint32_t v){memcpy(d+o,&v,4);}
static void u64(uint8_t*d,unsigned o,uint64_t v){memcpy(d+o,&v,8);}
static void f32(uint8_t*d,unsigned o,float v){memcpy(d+o,&v,4);}
static void ubo(uint8_t*d,unsigned table,unsigned index,uint64_t address,unsigned bytes){
 pan_pack((struct mali_uniform_buffer_packed*)(d+table+index*8),UNIFORM_BUFFER,c){
  c.pointer=address;c.entries=(bytes+15)/16;
 }
}
static void attr(uint8_t*d,unsigned at,unsigned buffer,unsigned format,unsigned swizzle,unsigned off){
 pan_pack((struct mali_attribute_packed*)(d+at),ATTRIBUTE,c){
  c.buffer_index=buffer;c.offset_enable=true;c.format=(format<<12)|swizzle;c.offset=off;
 }
}
static void buf(uint8_t*d,unsigned at,uint64_t address,unsigned stride,unsigned bytes){
 pan_pack((struct mali_attribute_buffer_packed*)(d+at),ATTRIBUTE_BUFFER,c){
  c.pointer=address;c.stride=stride;c.size=bytes;
 }
}
static void framebuffer(uint8_t*d,uint64_t VA,unsigned format,const A5RuntimeImage*out){
 u32(d,FB+4,31); /* released v4 local storage, TLS/WLS bothzero */
 pan_section_pack(d+FB,FRAMEBUFFER,PARAMETERS,c){
  c.internal_format=format==2?MALI_COLOR_BUFFER_INTERNAL_FORMAT_RAW_VALUE:
     format==4?MALI_COLOR_BUFFER_INTERNAL_FORMAT_R5G5B5A1:MALI_COLOR_BUFFER_INTERNAL_FORMAT_R8G8B8A8;
  c.swizzle=format==0||format==4?0x60a:0x688;
  c.color_writeback_format=format==2?MALI_COLOR_FORMAT_2_32B_CHANNELS:
     format==1?MALI_COLOR_FORMAT_R8:format==3?MALI_COLOR_FORMAT_R8G8:
     format==4?MALI_COLOR_FORMAT_R5G5B5A1:MALI_COLOR_FORMAT_R8G8B8A8;
  c.color_block_format=MALI_BLOCK_FORMAT_LINEAR;
  c.color_write_enable=true;
  c.tie_break_rule=MALI_TIE_BREAK_RULE_MINUS_180_IN_0_OUT;
  c.bound_max_x=out->width-1;c.bound_max_y=out->height-1;
  c.color_writeback.base=out->gpuVA;c.color_writeback.row_stride=out->rowBytes;

 }
 pan_section_pack(d+FB,FRAMEBUFFER,TILER,c){
  c.polygon_list=VA+POLY;c.polygon_list_body=VA+POLY_BODY;
  c.heap_start=VA+HEAP;c.heap_end=VA+HEAP+HEAP_SIZE;
  c.polygon_list_size=0x200+0x200*((out->width+1023)/1024)*((out->height+1023)/1024);c.hierarchy_mask=0x1c7;
 }
 u32(d,POLY_BODY,0xa0000000);
}
static void renderer(uint8_t*d,uint64_t VA,int home,int clear,int generic_color,int generic_textured,int textured_color,unsigned vs_regs,unsigned fs_regs,unsigned blend){
 pan_pack((struct mali_renderer_state_packed*)(d+VS_RSD),RENDERER_STATE,c){
  c.shader.shader=VA+VS_CODE+5;c.shader.attribute_count=generic_color?2:home||generic_textured?3:18;
  c.shader.varying_count=generic_color?3:home||generic_textured?4:clear?2:7;
  c.properties.uniform_buffer_count=generic_color?2:3;c.properties.work_register_count=vs_regs;
  c.properties.force_early_z=true;c.multisample_misc.sample_mask=0xffff;
  c.multisample_misc.depth_function=MALI_FUNC_ALWAYS;
 }
 pan_pack((struct mali_renderer_state_packed*)(d+FS_RSD),RENDERER_STATE,c){
  c.shader.shader=VA+FS_CODE+5;c.shader.texture_count=home?2:generic_textured?1:0;
  c.shader.sampler_count=home?2:generic_textured?1:0;c.shader.varying_count=textured_color?2:generic_color||generic_textured?1:home?1:clear?0:5;
  c.properties.uniform_buffer_count=generic_textured?5:generic_color?3:clear?1:4;c.properties.work_register_count=fs_regs;
  c.properties.force_early_z=true;c.multisample_misc.sample_mask=0xffff;
  c.multisample_misc.depth_function=MALI_FUNC_ALWAYS;
  c.stencil_mask_misc.alpha_test_compare_function=MALI_FUNC_ALWAYS;
  c.stencil_mask_misc.write_enable=true;c.stencil_mask_misc.dither_disable=true;
  c.multisample_misc.load_destination=!!blend;
  c.blend_equation.rgb.a=MALI_BLEND_OPERAND_A_SRC;
  c.blend_equation.rgb.b=blend?MALI_BLEND_OPERAND_B_DEST:MALI_BLEND_OPERAND_B_SRC;
  c.blend_equation.rgb.c=blend==A5RuntimeBlendScreen?MALI_BLEND_OPERAND_C_SRC:blend?MALI_BLEND_OPERAND_C_SRC_ALPHA:MALI_BLEND_OPERAND_C_ZERO;c.blend_equation.rgb.invert_c=!!blend;
  c.blend_equation.alpha.a=MALI_BLEND_OPERAND_A_SRC;
  c.blend_equation.alpha.b=blend?MALI_BLEND_OPERAND_B_DEST:MALI_BLEND_OPERAND_B_SRC;
  c.blend_equation.alpha.c=blend?MALI_BLEND_OPERAND_C_SRC_ALPHA:MALI_BLEND_OPERAND_C_ZERO;c.blend_equation.alpha.invert_c=!!blend;
  c.blend_equation.color_mask=0xf;
 }
}
static int span(uint64_t a,uint64_t n){return a&&n&&a<(UINT64_C(1)<<40)&&n<=(UINT64_C(1)<<40)-a;}
static int overlap(uint64_t a,uint64_t n,uint64_t b,uint64_t m){return a<b+m&&b<a+n;}
static int shader_tag(unsigned t){return t>=2&&t<=15&&t!=6&&t!=7;}
static unsigned bpp(unsigned f){return (f==70||f==80)?4:f==115?8:(f==1||f==10)?1:(f==30||f==43)?2:0;}
static int valid_image(const A5RuntimeImage*i){unsigned n=bpp(i->metalPixelFormat);
 return n&&span(i->gpuVA,i->bytes)&&!(i->gpuVA&63)&&i->width&&i->width<=2048&&i->height&&i->height<=2048&&
 i->rowBytes>=i->width*n&&!(i->rowBytes&15)&&(uint64_t)i->rowBytes*i->height<=i->bytes;
}
/* The 603 native fragment was compiled with SamplerState specID0=0:
 * normalized UVs. Words 0/2/4/6 (nearest/linear min/mag) yield identical
 * native code. The runtime sampler supplies filtering and clamp-to-edge
 * addressing. One source mip means every valid LOD resolves to level0. */
static int textured_sampler(const A5RuntimeSampler*s){
 return s->valid==1&&s->normalizedCoordinates==1&&s->maxAnisotropy>=1&&s->maxAnisotropy<=16&&
  !s->compareEnabled&&s->minFilter<=A5RuntimeSamplerLinear&&
  s->magFilter<=A5RuntimeSamplerLinear&&s->mipFilter<=A5RuntimeSamplerMipLinear&&
  s->sAddressMode==A5RuntimeSamplerClampEdge&&
  s->tAddressMode==A5RuntimeSamplerClampEdge&&
  s->rAddressMode==A5RuntimeSamplerClampEdge&&
  isfinite(s->lodMinClamp)&&isfinite(s->lodMaxClamp)&&
  s->lodMinClamp>=0&&s->lodMaxClamp>=s->lodMinClamp;
}
/* v4 stores an inline16-byte surface-with-stride for EVERY mip, in
 * level order. The logical view may begin at a nonzero physical atlas offset. */
static int texture_descriptor(uint8_t*d,unsigned at,const A5RuntimeMiscDraw*m,
 unsigned slot,unsigned format,unsigned swizzle){
 const A5RuntimeImage *base=&m->fragmentTextures[slot];
 const A5RuntimeMipChain *chain=&m->fragmentMips[slot];
 unsigned levels=chain->levelCount?chain->levelCount:1;
 if(levels>A5RuntimeMipLevels||32+16*levels>MIP_TEX_STRIDE)return A5RuntimeBounds;
 unsigned width=base->width,height=base->height;
 for(unsigned level=0;level<levels;level++){
  const A5RuntimeImage *im=chain->levelCount?chain->levels+level:base;
  if(!valid_image(im)||im->metalPixelFormat!=base->metalPixelFormat||im->width!=width||im->height!=height||
     (level==0&&(im->gpuVA!=base->gpuVA||im->rowBytes!=base->rowBytes||im->bytes!=base->bytes))||
     overlap(im->gpuVA,im->bytes,m->draw.descriptorGPUVA,SIZE))return A5RuntimeBounds;
  for(unsigned i=0;i<m->draw.profile->passCount;i++){
   const A5RuntimeImage *out=m->colorAttachments+m->draw.profile->passes[i].logicalTarget;
   if(overlap(im->gpuVA,im->bytes,out->gpuVA,out->bytes))return A5RuntimeUnsupported;
  }
  for(unsigned i=0;i<level;i++)if(overlap(im->gpuVA,im->bytes,chain->levels[i].gpuVA,chain->levels[i].bytes))return A5RuntimeBounds;
  pan_pack((struct mali_surface_with_stride_packed*)(d+at+32+16*level),SURFACE_WITH_STRIDE,c){
   c.pointer=im->gpuVA;c.row_stride=im->rowBytes;c.surface_stride=im->rowBytes*im->height;
  }
  if(level+1<levels&&width==1&&height==1)return A5RuntimeBounds;
  width=width>1?width>>1:1;height=height>1?height>>1:1;
 }
 pan_pack((struct mali_texture_packed*)(d+at),TEXTURE,c){
  c.width=base->width;c.height=base->height;c.array_size=1;c.levels=levels;
  c.format=(format<<12)|swizzle;c.dimension=MALI_TEXTURE_DIMENSION_2D;
  c.texel_ordering=MALI_TEXTURE_LAYOUT_LINEAR;c.swizzle=0x688;
 }
 return A5RuntimeOK;
}
static float texture_max_lod(const A5RuntimeSampler*s,unsigned levels){
 if(s->mipFilter==A5RuntimeSamplerMipNone)return fminf(s->lodMinClamp,(float)(levels-1))+1.0f/256.0f;
 return fminf(s->lodMaxClamp,(float)(levels-1));
}
static int textured_image(uint8_t*d,const A5RuntimeMiscDraw*m){
 const A5RuntimeImage*im=&m->fragmentTextures[3];const A5RuntimeSampler*s=&m->fragmentSamplers[0];
 uint64_t VA=m->draw.descriptorGPUVA;
 if(!textured_sampler(s)||!valid_image(im)||
    (im->metalPixelFormat!=70&&im->metalPixelFormat!=80&&im->metalPixelFormat!=30&&im->metalPixelFormat!=10&&im->metalPixelFormat!=1)||
    (m->draw.profile->profileID==603&&im->metalPixelFormat!=80&&im->metalPixelFormat!=70)||
    (m->draw.profile->profileID==606&&im->metalPixelFormat!=1)||
    (uint64_t)im->rowBytes*im->height>INT32_MAX||
    overlap(im->gpuVA,im->bytes,VA,SIZE))return A5RuntimeUnsupported;
 for(unsigned i=0;i<m->draw.profile->passCount;++i){
  const A5RuntimeImage*dest=&m->colorAttachments[m->draw.profile->passes[i].logicalTarget];
  if(overlap(im->gpuVA,im->bytes,dest->gpuVA,dest->bytes))return A5RuntimeUnsupported;
 }
 const unsigned format=(im->metalPixelFormat==70||im->metalPixelFormat==80)?MALI_RGBA8_UNORM:
  im->metalPixelFormat==30?MALI_RG8_UNORM:MALI_R8_UNORM;
 const unsigned swizzle=im->metalPixelFormat==80?0x60a:im->metalPixelFormat==70?0x688:
  im->metalPixelFormat==30?RG_SWIZZLE:im->metalPixelFormat==1?A_SWIZZLE:R_SWIZZLE;
 unsigned levels=m->fragmentMips[3].levelCount?m->fragmentMips[3].levelCount:1;
 unsigned tex=levels>1?MIP_TEX:TEX0;
 int textureStatus=texture_descriptor(d,tex,m,3,format,swizzle);if(textureStatus)return textureStatus;
 if(s->maxAnisotropy>1)return A5RuntimeUnsupported; /* static code has no shader anisotropy */
 u64(d,TEX_TABLE,VA+tex);
 pan_pack((struct mali_sampler_packed*)(d+SAMPLERS),SAMPLER,c){
  c.normalized_coordinates=true;c.seamless_cube_map=false;
  c.minify_nearest=s->minFilter==A5RuntimeSamplerNearest;
  c.magnify_nearest=s->magFilter==A5RuntimeSamplerNearest;
  c.mipmap_mode=s->mipFilter==A5RuntimeSamplerMipLinear?MALI_MIPMAP_MODE_TRILINEAR:MALI_MIPMAP_MODE_NEAREST;
  c.wrap_mode_s=MALI_WRAP_MODE_CLAMP_TO_EDGE;
  c.wrap_mode_t=MALI_WRAP_MODE_CLAMP_TO_EDGE;
  c.wrap_mode_r=MALI_WRAP_MODE_CLAMP_TO_EDGE;
  c.minimum_lod=fminf(s->lodMinClamp,(float)(levels-1));
  c.maximum_lod=levels>1?texture_max_lod(s,levels):0;
 }
 /* The normalized-coordinate native shader samples interpolated UV directly.
  * It does not read synthetic texture dimensions from FS_SYS. */
 return A5RuntimeOK;
}
/* Preserve the verified one-Texture3/Sampler0 descriptor layout exactly.
 * Multi-resource or half4 inputs use the independent expanded table below. */
static int dynamic_legacy_texture(const A5RuntimeMiscDraw*m){
 unsigned textures=0,samplers=0;const A5MaliCompiledProfile*p=m->draw.profile;
 if(m->fragmentTextures[3].metalPixelFormat==115||m->fragmentMips[3].levelCount>1||
    (p->flags&A5MaliProfileShaderAnisotropy))return 0;
 for(unsigned i=0;i<p->resourceCount;i++){
  const A5MaliCompiledResource*r=p->resources+i;
  if(r->kind==A5MaliResourceTexture){if(r->metalIndex!=3||r->nativeIndex||textures++)return 0;}
  if(r->kind==A5MaliResourceSampler){if(r->metalIndex||r->nativeIndex||samplers++)return 0;}
 }
 return textures==1&&samplers==1;
}
/* Four independently reflected combined image/sampler bindings live in a
 * separate descriptor region. Legacy descriptor offsets remain byte-identical.
 * No assumption about a Metal texture/sampler slot is made on this route. */
_Static_assert(BIG_FS_CODE+0x4000<=HEAP,"expanded fragment must not overlap tiler heap");
_Static_assert(MIP_TEX+4*MIP_TEX_STRIDE<=VS_CODE,"mip payloads must not overlap shader code");
_Static_assert(DYNAMIC_TEX+4*64<=DYNAMIC_TEX_TABLE,"dynamic texture table overlap");
_Static_assert(DYNAMIC_TEX_TABLE+4*8<=DYNAMIC_SAMPLERS,"dynamic sampler table overlap");
_Static_assert(DYNAMIC_SAMPLERS+4*MALI_SAMPLER_LENGTH<=VS_CODE,"dynamic code overlap");
static int dynamic_images(uint8_t*d,const A5RuntimeMiscDraw*m){
 const A5MaliCompiledProfile*p=m->draw.profile;uint64_t va=m->draw.descriptorGPUVA;
 for(unsigned n=0;n<p->resourceCount;n++){
  const A5MaliCompiledResource*r=p->resources+n;
  if(r->kind!=A5MaliResourceTexture)continue;
  const A5MaliCompiledResource*sampler=NULL;
  for(unsigned j=0;j<p->resourceCount;j++){
   const A5MaliCompiledResource*t=p->resources+j;
   if(t->kind==A5MaliResourceSampler&&t->stage==2&&t->nativeIndex==r->nativeIndex&&
      t->bindingIndex==r->bindingIndex){if(sampler)return A5RuntimeUnsupported;sampler=t;}
  }
  if(!sampler||r->nativeIndex>=4||r->metalIndex>=31||
    (!(sampler->flags&A5MaliResourceImmutableSampler)&&sampler->metalIndex>=31))return A5RuntimeUnsupported;
  const A5RuntimeImage*im=m->fragmentTextures+r->metalIndex;
  A5RuntimeSampler immutable={0};
  const A5RuntimeSampler*sm=&immutable;
  if(sampler->flags&A5MaliResourceImmutableSampler){
   const A5MaliCompiledSampler*state=NULL;
   for(unsigned j=0;j<p->immutableSamplerCount;j++)if(p->immutableSamplers[j].nativeIndex==r->nativeIndex)state=p->immutableSamplers+j;
   if(!state)return A5RuntimeUnsupported;
   immutable=(A5RuntimeSampler){1,state->minFilter,state->magFilter,state->mipFilter,
      state->sAddressMode,state->tAddressMode,state->rAddressMode,state->normalizedCoordinates,
      1,0,state->lodMinClamp,state->lodMaxClamp};
  }else sm=m->fragmentSamplers+sampler->metalIndex;
  if((!(sampler->flags&A5MaliResourceImmutableSampler)&&!textured_sampler(sm))||!valid_image(im)||
     (im->metalPixelFormat!=70&&im->metalPixelFormat!=80&&im->metalPixelFormat!=115&&im->metalPixelFormat!=30&&im->metalPixelFormat!=10&&im->metalPixelFormat!=1)||
     overlap(im->gpuVA,im->bytes,va,SIZE))return A5RuntimeUnsupported;
  for(unsigned j=0;j<p->passCount;j++){
   const A5RuntimeImage*out=m->colorAttachments+p->passes[j].logicalTarget;
   if(overlap(im->gpuVA,im->bytes,out->gpuVA,out->bytes))return A5RuntimeUnsupported;
  }
  unsigned format=(im->metalPixelFormat==70||im->metalPixelFormat==80)?MALI_RGBA8_UNORM:
   im->metalPixelFormat==115?MALI_RGBA16F:im->metalPixelFormat==30?MALI_RG8_UNORM:MALI_R8_UNORM;
  unsigned swizzle=im->metalPixelFormat==80?0x60a:(im->metalPixelFormat==70||im->metalPixelFormat==115)?0x688:
   im->metalPixelFormat==30?RG_SWIZZLE:im->metalPixelFormat==1?A_SWIZZLE:R_SWIZZLE;
  unsigned levels=m->fragmentMips[r->metalIndex].levelCount?m->fragmentMips[r->metalIndex].levelCount:1;
  unsigned tex=levels>1?MIP_TEX+r->nativeIndex*MIP_TEX_STRIDE:DYNAMIC_TEX+r->nativeIndex*64;
  int textureStatus=texture_descriptor(d,tex,m,r->metalIndex,format,swizzle);if(textureStatus)return textureStatus;
  if(sm->maxAnisotropy>1&&!(p->flags&A5MaliProfileShaderAnisotropy))return A5RuntimeUnsupported;
  u64(d,DYNAMIC_TEX_TABLE+r->nativeIndex*8,va+tex);
  pan_pack((struct mali_sampler_packed*)(d+DYNAMIC_SAMPLERS+r->nativeIndex*MALI_SAMPLER_LENGTH),SAMPLER,c){
   c.normalized_coordinates=true;c.seamless_cube_map=false;
   c.minify_nearest=sm->minFilter==A5RuntimeSamplerNearest;
   c.magnify_nearest=sm->magFilter==A5RuntimeSamplerNearest;
   c.mipmap_mode=sm->mipFilter==A5RuntimeSamplerMipLinear?MALI_MIPMAP_MODE_TRILINEAR:MALI_MIPMAP_MODE_NEAREST;
   c.wrap_mode_s=sm->sAddressMode==A5RuntimeSamplerRepeat?MALI_WRAP_MODE_REPEAT:
    sm->sAddressMode==A5RuntimeSamplerClampBorder?MALI_WRAP_MODE_CLAMP_TO_BORDER:MALI_WRAP_MODE_CLAMP_TO_EDGE;
   c.wrap_mode_t=sm->tAddressMode==A5RuntimeSamplerRepeat?MALI_WRAP_MODE_REPEAT:
    sm->tAddressMode==A5RuntimeSamplerClampBorder?MALI_WRAP_MODE_CLAMP_TO_BORDER:MALI_WRAP_MODE_CLAMP_TO_EDGE;
   c.wrap_mode_r=sm->rAddressMode==A5RuntimeSamplerRepeat?MALI_WRAP_MODE_REPEAT:
    sm->rAddressMode==A5RuntimeSamplerClampBorder?MALI_WRAP_MODE_CLAMP_TO_BORDER:MALI_WRAP_MODE_CLAMP_TO_EDGE;
   c.minimum_lod=fminf(sm->lodMinClamp,(float)(levels-1));
   c.maximum_lod=levels>1?texture_max_lod(sm,levels):(sampler->flags&A5MaliResourceImmutableSampler)?sm->lodMaxClamp:0;
   c.border_color_r=0;c.border_color_g=0;c.border_color_b=0;c.border_color_a=0;
  }
  unsigned q=FS_SYS+352+32*r->nativeIndex;
  u32(d,q,levels);u32(d,q+4,im->width);u32(d,q+8,im->height);u32(d,q+12,sm->maxAnisotropy);
  f32(d,q+16,sm->lodMinClamp);
  f32(d,q+20,levels>1?texture_max_lod(sm,levels):(sampler->flags&A5MaliResourceImmutableSampler)?sm->lodMaxClamp:0);
  f32(d,q+24,0); /* immutable/runtime accepted states have zero LOD bias */
 }
 return A5RuntimeOK;
}
/* Admit only the captured, host-compiled native VS/FS pairs below. This is
 * an encoder contract, not evidence that a stock iOS draw uses the pair.
 * Inactive Metal attributes 1/2 are still part of the original 4QC layout;
 * native attr slots 0/1 are the surviving position and half4 colour inputs.
 * The captured FS constant blob and FB1 uniform are dead in this exact code.
 */
static int generic_color_contract(const A5MaliCompiledProfile*p){
 const unsigned sourceOver=!!(p->flags&A5MaliProfileSourceOverBlend);
 if((p->profileID!=600&&p->profileID!=601&&p->profileID!=602)||
    p->flags!=((sourceOver?A5MaliProfileSourceOverBlend:0)|(p->flags&(A5MaliProfileScreenBlend|A5MaliProfileRenderState)))||((p->flags&A5MaliProfileScreenBlend)&&!sourceOver)||p->passCount!=1||
    p->passes[0].passID!=p->profileID||p->passes[0].logicalTarget||
    (p->colorFormats[0]!=80&&(p->profileID!=602||p->colorFormats[0]!=43))||p->attributeCount!=4||!p->attributes||
    p->layoutCount!=1||!p->layouts||p->resourceCount!=1||!p->resources||
    p->pushFieldCount!=2||!p->pushFields||p->attachmentContractCount!=(sourceOver?2u:1u)||
    !p->attachmentContracts)return 0;
 if(!p->vertexName||strcmp(p->vertexName,p->profileID==602?"fixed_vert_lph_spc":"std_vert0_lph")||
    !p->fragmentName||strcmp(p->fragmentName,p->profileID==600?"fixed_frag_lph_cpf":"fixed_frag_lph_cph"))return 0;
 for(unsigned i=1;i<8;++i)if(p->colorFormats[i])return 0;
 static const unsigned formats[]={31,29,29,27},offsets[]={0,16,24,32};
 for(unsigned i=0;i<4;++i){const A5MaliCompiledVertexAttribute*a=p->attributes+i;
  if(a->index!=i||(a->format!=formats[i]&&(i||a->format!=29))||a->offset!=offsets[i]||a->bufferIndex!=1)return 0;
 }
 const A5MaliCompiledVertexLayout*l=p->layouts;
 if(l->index!=1||l->stride!=48||l->stepFunction!=1||l->stepRate!=1)return 0;
 const A5MaliCompiledResource*r=p->resources;
 if(r->stage!=A5MaliStageVertex||r->kind!=A5MaliResourceBuffer||
    r->metalIndex!=2||r->bindingIndex||r->nativeIndex!=1||
    r->flags!=A5MaliResourceRead||r->windowOffset||r->uniformBytes!=64||
    r->sysvalOffset||r->pushOffset)return 0;
 const A5MaliCompiledPushField*vs=p->pushFields,*fs=vs+1;
 if(vs->stage!=A5MaliStageVertex||vs->kind!=A5MaliPushBindOffset||
    vs->metalIndex!=2||vs->offset||vs->bytes!=4||vs->value||
    fs->stage!=A5MaliStageFragment||fs->kind!=A5MaliPushColorWriteRule||
    fs->metalIndex||fs->offset!=68||fs->bytes!=4||fs->value!=0x2222)return 0;
 for(unsigned c=0;c<p->attachmentContractCount;++c)for(unsigned i=0;i<8;++i){
  const A5MaliCompiledAttachmentState*a=&p->attachmentContracts[c].attachments[i];
  unsigned over=c==1&&i==0;
  if((p->flags&A5MaliProfileRenderState)&&c==1&&i==0){
   if(A5MaliLowerRenderState(a).route!=A5MaliStateFixed)return 0;
   continue;
  }
  /* Fixed ROP supports inverse source alpha or inverse source color on RT0. All
   * unattached slots and the existing copy contract remain exact. */
  if(a->writeMask!=15||a->blendEnabled!=over||a->rgbOperation||
     a->alphaOperation||a->sourceRGB!=1||a->destinationRGB!=(over?((p->flags&A5MaliProfileScreenBlend)?3u:5u):0u)||
     a->sourceAlpha!=1||a->destinationAlpha!=(over?((p->flags&A5MaliProfileScreenBlend)?3u:5u):0u))return 0;
 }
 const A5MaliCompiledPass*pass=p->passes;
 return pass->vertex.sha256&&pass->fragment.sha256&&
  !strcmp(pass->vertex.sha256,"3cdf2b0db0b9992ce887242e7cac282cd70c3f8051e3ace3e791a0b676193a79")&&
  !strcmp(pass->fragment.sha256,"e66041333f6452510cda4d0ee1f1c1edf443a12007a989871a1546791deb0834")&&
  pass->vertex.byteCount==1808&&pass->fragment.byteCount==848&&
  pass->vertex.workRegisters==8&&pass->fragment.workRegisters==6;
}
/* This is a separate, actually compiled texture specialization. Its vertex
 * reads original Metal attr0/attr1/attr3, exports UV in VAR0 and colour in
 * VAR1. Texture3/Sampler0 uses FB2 bias. Profile606 additionally reads
 * FragmentBuffer1.float4@112 to clamp UV; prior603..605 leave FB1 dead.
 * The translator's synthetic blob remains dead in all pinned native pairs. */
static int generic_textured_contract(const A5MaliCompiledProfile*p){
 const int coord5=p->profileID==606;
 if((p->profileID!=603&&p->profileID!=604&&p->profileID!=605&&!coord5)||
    p->flags!=(A5MaliProfileSourceOverBlend|(p->flags&(A5MaliProfileScreenBlend|A5MaliProfileRenderState)))||p->passCount!=1||!p->passes||
    p->passes[0].passID!=p->profileID||p->passes[0].logicalTarget||
    !p->vertexName||strcmp(p->vertexName,"fixed_vert_lph_spc")||
    !p->fragmentName||strcmp(p->fragmentName,"fixed_frag_lph_cph")||
    (p->colorFormats[0]!=80&&p->colorFormats[0]!=43)||p->attributeCount!=4||!p->attributes||
    p->layoutCount!=1||!p->layouts||p->resourceCount!=(coord5?6u:5u)||!p->resources||
    p->pushFieldCount!=(coord5?5u:4u)||!p->pushFields||p->attachmentContractCount!=2||
    !p->attachmentContracts)return 0;
 for(unsigned i=1;i<8;++i)if(p->colorFormats[i])return 0;
 static const unsigned formats[]={31,29,29,27},offsets[]={0,16,24,32};
 for(unsigned i=0;i<4;++i){const A5MaliCompiledVertexAttribute*a=p->attributes+i;
  if(a->index!=i||(a->format!=formats[i]&&(i||a->format!=29))||a->offset!=offsets[i]||a->bufferIndex!=1)return 0;
 }
 const A5MaliCompiledVertexLayout*l=p->layouts;
 if(l->index!=1||l->stride!=48||l->stepFunction!=1||l->stepRate!=1)return 0;
 static const A5MaliCompiledResource expected[]={
  {1,1,2,0,1,1,0,64,0,0},
  {1,1,3,1,2,1,0,16,0,4},
  {2,1,1,2,3,1,0,128,0,64},
  {2,1,2,3,4,1,0,8,0,68},
  {2,2,3,5,0,1,0,0,0,0},
  {2,3,0,5,0,1,0,0,0,0}
 };
 for(unsigned i=0;i<p->resourceCount;++i){const A5MaliCompiledResource*a=&p->resources[i],*b=&expected[i+(!coord5&&i>=2)];
  if(a->stage!=b->stage||a->kind!=b->kind||a->metalIndex!=b->metalIndex||
     a->bindingIndex!=b->bindingIndex||a->nativeIndex!=b->nativeIndex||
     a->flags!=b->flags||a->windowOffset!=b->windowOffset||
     a->uniformBytes!=b->uniformBytes||a->sysvalOffset!=b->sysvalOffset||
     a->pushOffset!=b->pushOffset)return 0;
 }
 static const A5MaliCompiledPushField pushes[]={
  {1,1,2,0,4,0},{1,1,3,4,4,0},{2,1,1,64,4,0},
  {2,1,2,68,4,0},{2,2,0,72,4,0x2222}
 };
 for(unsigned i=0;i<p->pushFieldCount;++i){const A5MaliCompiledPushField*a=&p->pushFields[i],*b=&pushes[i+(!coord5&&i>=2)];
  if(a->stage!=b->stage||a->kind!=b->kind||a->metalIndex!=b->metalIndex||
     a->offset!=b->offset||a->bytes!=b->bytes||a->value!=b->value)return 0;
 }
 for(unsigned contract=0;contract<2;++contract){
  for(unsigned i=0;i<8;++i){
   const A5MaliCompiledAttachmentState*a=&p->attachmentContracts[contract].attachments[i];
   const int source_over=contract==1&&i==0;
  if((p->flags&A5MaliProfileRenderState)&&contract==1&&i==0){
   if(A5MaliLowerRenderState(a).route!=A5MaliStateFixed)return 0;
   continue;
  }
   if(a->writeMask!=15||a->blendEnabled!=source_over||a->rgbOperation||a->alphaOperation||
      a->sourceRGB!=1||a->destinationRGB!=(source_over?((p->flags&A5MaliProfileScreenBlend)?3:5):0)||
      a->sourceAlpha!=1||a->destinationAlpha!=(source_over?((p->flags&A5MaliProfileScreenBlend)?3:5):0))return 0;
  }
 }
 const A5MaliCompiledPass*pass=p->passes;
 const char*fragmentHash=p->profileID==603?
  "e4cf4d31a87bde096cc7cc57a12818f79296e3998d22d9c6c5139a9887f30047":
  p->profileID==604?
  "90d93347ca8bb50eef500ac2296e71dfb8298a58bd24d903f913295560798424":
  p->profileID==605?
  "48bccbbdd2b788137ff228c7677e87a574ccfcd29f324a7bc44015bc15f3e2ce":
  "5f1a9b4a037cb93f756bd3259f717d45c1a6622ee15d6504917c1582bf630e36";
 const unsigned fragmentBytes=p->profileID==603?880:p->profileID==604?1120:896;
 const unsigned fragmentRegs=p->profileID==604?6:5;
 return pass->vertex.sha256&&pass->fragment.sha256&&
  !strcmp(pass->vertex.sha256,"e0c51d2171b28c891677cdb1f1c98032bee0f03bb64af694a8321d711159fc96")&&
  !strcmp(pass->fragment.sha256,fragmentHash)&&
  pass->vertex.byteCount==2192&&pass->fragment.byteCount==fragmentBytes&&
  pass->vertex.workRegisters==8&&pass->fragment.workRegisters==fragmentRegs;
}
/* Dynamic code is compiled from the pinned source library by the root worker.
 * Its module fingerprint is deliberately not enumerated here. This independent
 * encoder gate admits only resource/packing semantics this emitter implements. */
static int dynamic_textured_contract(const A5MaliCompiledProfile*p){
 if(p->profileID!=A5MaliDynamicProfileID||
    !(p->flags&A5MaliProfileDynamicStages)||
    (p->flags&~(A5MaliProfileDynamicStages|A5MaliProfileDynamicColorVarying|A5MaliProfileSourceOverBlend|A5MaliProfileFramebufferFetch|A5MaliProfileFragmentPosition|A5MaliProfileFragmentNoInputs|A5MaliProfileVertexColorOnly|A5MaliProfileVertexTwoUV|A5MaliProfileFragmentTwoUV|A5MaliProfileFragmentColorOnly|A5MaliProfileFragmentNoTextures|A5MaliProfileScreenBlend|A5MaliProfileRenderState|A5MaliProfileShaderBlend|A5MaliProfileVertexNoColor|A5MaliProfileShaderAnisotropy))||
    !(p->flags&A5MaliProfileSourceOverBlend)||p->passCount!=1||!p->passes||
    p->passes[0].passID!=p->profileID||p->passes[0].logicalTarget||
    !p->vertexName||!p->vertexName[0]||!p->fragmentName||!p->fragmentName[0]||
    (p->colorFormats[0]!=80&&p->colorFormats[0]!=43)||p->viewportWidth||p->viewportHeight||
    p->attributeCount<2||p->attributeCount>4||!p->attributes||p->layoutCount!=1||!p->layouts||
    !p->resourceCount||p->resourceCount>16||!p->resources||
    !p->pushFieldCount||p->pushFieldCount>16||!p->pushFields||
    p->attachmentContractCount!=2||!p->attachmentContracts)return 0;
 for(unsigned i=1;i<8;++i)if(p->colorFormats[i])return 0;
 static const unsigned formats[]={31,29,29,27};
 const A5MaliCompiledVertexLayout*l=p->layouts;
 if(l->index!=1||l->stride<8||l->stride>2048||(l->stride&3)||l->stepFunction!=1||l->stepRate!=1)return 0;
 unsigned attributeMask=0,requiredAttributes=(p->flags&A5MaliProfileVertexColorOnly)?0x9u:
  (p->flags&A5MaliProfileVertexNoColor)?0x7u:
  (p->flags&A5MaliProfileVertexTwoUV)?0xfu:0xbu;
 for(unsigned i=0;i<p->attributeCount;++i){const A5MaliCompiledVertexAttribute*a=p->attributes+i;
  unsigned index=a->index;
  if(index>=4||(i&&index<=p->attributes[i-1].index)||
     (a->format!=formats[index]&&(index||a->format!=29))||
     a->bufferIndex!=1)return 0;
  unsigned width=a->format==31?16:8,alignment=index==3?2:4;
  if(a->offset%alignment||a->offset>l->stride||width>l->stride-a->offset)return 0;
  attributeMask|=1u<<index;
 }
 if((attributeMask&requiredAttributes)!=requiredAttributes)return 0;
 unsigned textures=0,samplers=0,fetches=0;uint32_t textureBindings[4]={0},samplerBindings[4]={0};
 uint32_t bindings[2]={0},slots[2]={0},descriptorBindings[2]={0};
 for(unsigned i=0;i<p->resourceCount;++i){const A5MaliCompiledResource*r=p->resources+i;
  if((r->stage!=1&&r->stage!=2)||r->windowOffset||r->sysvalOffset)return 0;
  unsigned allowed=A5MaliResourceRead|(r->kind==A5MaliResourceBuffer?A5MaliResourcePadUniformTail:
   r->kind==A5MaliResourceSampler?A5MaliResourceImmutableSampler:0);
  if(!(r->flags&A5MaliResourceRead)||(r->flags&~allowed))return 0;
  unsigned st=r->stage-1;
  if(r->kind==A5MaliResourceBuffer){
   if(r->metalIndex>=31||r->bindingIndex>=7||r->nativeIndex!=r->bindingIndex+1||
      !r->uniformBytes||r->uniformBytes>4096||r->pushOffset>76||(r->pushOffset&3)||
      (bindings[st]&(1u<<r->bindingIndex))||(slots[st]&(1u<<r->metalIndex)))return 0;
   if(descriptorBindings[st]&(1u<<r->bindingIndex))return 0;
   descriptorBindings[st]|=1u<<r->bindingIndex;
   bindings[st]|=1u<<r->bindingIndex;slots[st]|=1u<<r->metalIndex;
  }else if(r->kind==A5MaliResourceTexture){
   if(r->stage!=2||r->metalIndex>=31||r->bindingIndex>=32||r->nativeIndex>=4||r->uniformBytes||r->pushOffset||
      (textures&(1u<<r->nativeIndex)))return 0;
   if(descriptorBindings[1]&(1u<<r->bindingIndex))return 0;
   descriptorBindings[1]|=1u<<r->bindingIndex;
   textures|=1u<<r->nativeIndex;textureBindings[r->nativeIndex]=r->bindingIndex;
  }else if(r->kind==A5MaliResourceSampler){
   if(r->stage!=2||((r->flags&A5MaliResourceImmutableSampler)?r->metalIndex!=31:r->metalIndex>=31)||r->bindingIndex>=32||r->nativeIndex>=4||r->uniformBytes||r->pushOffset||
      (samplers&(1u<<r->nativeIndex)))return 0;
   samplers|=1u<<r->nativeIndex;samplerBindings[r->nativeIndex]=r->bindingIndex;
  }else if(r->kind==A5MaliResourceInputAttachment){
   if(!(p->flags&A5MaliProfileFramebufferFetch)||fetches++||r->stage!=2||r->metalIndex||
      r->bindingIndex>=32||r->nativeIndex||r->uniformBytes||r->pushOffset||
      (descriptorBindings[1]&(1u<<r->bindingIndex)))return 0;
   descriptorBindings[1]|=1u<<r->bindingIndex;
  }else return 0;
 }
 if(!!(p->flags&A5MaliProfileFramebufferFetch)!=(fetches==1))return 0;
 if((p->flags&A5MaliProfileVertexColorOnly)&&(!(p->flags&(A5MaliProfileFragmentNoInputs|A5MaliProfileFragmentColorOnly))||(p->flags&A5MaliProfileVertexTwoUV)))return 0;
 if((p->flags&A5MaliProfileFragmentTwoUV)&&(!(p->flags&A5MaliProfileVertexTwoUV)||(p->flags&A5MaliProfileFragmentNoInputs)))return 0;
 if((p->flags&A5MaliProfileVertexNoColor)&&(!(p->flags&A5MaliProfileVertexTwoUV)||
    (p->flags&(A5MaliProfileVertexColorOnly|A5MaliProfileDynamicColorVarying))))return 0;
 if((p->flags&A5MaliProfileFragmentNoTextures)&&(p->flags&(A5MaliProfileFragmentNoInputs|A5MaliProfileFragmentColorOnly)))return 0;
 if(p->flags&A5MaliProfileFragmentNoInputs){
  /* Constant and ordered-fetch shaders both have genuine empty interpolant
   * tables. Fetch is independently matched to a real input-attachment above. */
  if(textures||samplers||
     (p->flags&(A5MaliProfileDynamicColorVarying|A5MaliProfileFragmentPosition|A5MaliProfileFragmentColorOnly)))return 0;
 }else if(p->flags&A5MaliProfileFragmentColorOnly){
  if(textures||samplers||!(p->flags&A5MaliProfileDynamicColorVarying)||
     (p->flags&(A5MaliProfileFragmentPosition|A5MaliProfileFragmentTwoUV)))return 0;
 }else if(p->flags&A5MaliProfileFragmentNoTextures){
  if(textures||samplers)return 0;
 }else if(!textures||textures!=samplers)return 0;
 for(unsigned i=0;i<4;i++)if((textures&(1u<<i))&&textureBindings[i]!=samplerBindings[i])return 0;
 if((p->flags&A5MaliProfileShaderBlend)&&!(p->flags&A5MaliProfileRenderState))return 0;
 unsigned immutableMask=0,constantMask=0;
 for(unsigned i=0;i<p->resourceCount;i++)if(p->resources[i].kind==A5MaliResourceSampler&&
   (p->resources[i].flags&A5MaliResourceImmutableSampler))constantMask|=1u<<p->resources[i].nativeIndex;
 if(p->immutableSamplerCount>4||(p->immutableSamplerCount&&!p->immutableSamplers))return 0;
 for(unsigned i=0;i<p->immutableSamplerCount;i++){
  const A5MaliCompiledSampler*s=p->immutableSamplers+i;
  if(s->nativeIndex>=4||(immutableMask&(1u<<s->nativeIndex))||s->minFilter>1||s->magFilter>1||s->mipFilter||
     (s->sAddressMode!=A5RuntimeSamplerRepeat&&s->sAddressMode!=A5RuntimeSamplerClampEdge&&s->sAddressMode!=A5RuntimeSamplerClampBorder)||
     (s->tAddressMode!=A5RuntimeSamplerRepeat&&s->tAddressMode!=A5RuntimeSamplerClampEdge&&s->tAddressMode!=A5RuntimeSamplerClampBorder)||
     (s->rAddressMode!=A5RuntimeSamplerRepeat&&s->rAddressMode!=A5RuntimeSamplerClampEdge&&s->rAddressMode!=A5RuntimeSamplerClampBorder)||
     s->normalizedCoordinates!=1||!isfinite(s->lodMinClamp)||!isfinite(s->lodMaxClamp)||
     s->lodMinClamp<0||s->lodMaxClamp<s->lodMinClamp||s->lodMaxClamp>15)return 0;
  immutableMask|=1u<<s->nativeIndex;
 }
 if(immutableMask!=constantMask)return 0;
 uint32_t used[2]={0};
 for(unsigned i=0;i<p->pushFieldCount;++i){const A5MaliCompiledPushField*f=p->pushFields+i;
  if((f->stage!=1&&f->stage!=2)||f->bytes!=4||f->offset>76||(f->offset&3)||
     (used[f->stage-1]&(1u<<(f->offset/4))))return 0;
  used[f->stage-1]|=1u<<(f->offset/4);
  if(f->kind==A5MaliPushBindOffset){
   unsigned match=0;
   for(unsigned j=0;j<p->resourceCount;++j){const A5MaliCompiledResource*r=p->resources+j;
    if(r->stage==f->stage&&r->kind==A5MaliResourceBuffer&&r->metalIndex==f->metalIndex&&r->pushOffset==f->offset)match++;
   }
   if(match!=1||f->value)return 0;
  }else if(f->kind!=A5MaliPushColorWriteRule||f->stage!=2||f->value!=0x2222||f->metalIndex)return 0;
 }
 for(unsigned i=0;i<p->resourceCount;++i){const A5MaliCompiledResource*r=p->resources+i;
  if(r->kind==A5MaliResourceBuffer&&!(used[r->stage-1]&(1u<<(r->pushOffset/4))))return 0;
 }
 for(unsigned c=0;c<2;++c)for(unsigned i=0;i<8;++i){
  const A5MaliCompiledAttachmentState*a=&p->attachmentContracts[c].attachments[i];
  unsigned over=c==1&&i==0;
  if((p->flags&A5MaliProfileRenderState)&&c==1&&i==0){
   unsigned route=A5MaliLowerRenderState(a).route;
   if(p->flags&A5MaliProfileShaderBlend){
    if(!(p->flags&A5MaliProfileDynamicStages)||route!=A5MaliStateNeedsShader||
       a->sourceRGB>14||a->destinationRGB>14||a->sourceAlpha>14||a->destinationAlpha>14)return 0;
   }else if(route!=A5MaliStateFixed)return 0;
   continue;
  }
  if(a->writeMask!=15||a->blendEnabled!=over||a->rgbOperation||a->alphaOperation||
     a->sourceRGB!=1||a->sourceAlpha!=1||a->destinationRGB!=(over?((p->flags&A5MaliProfileScreenBlend)?3u:5u):0u)||
     a->destinationAlpha!=(over?((p->flags&A5MaliProfileScreenBlend)?3u:5u):0u))return 0;
 }
 return 1;
}
int A5MaliDynamicRuntimeProfileSupported(const A5MaliCompiledProfile*p){
 return p&&dynamic_textured_contract(p);
}
uint32_t A5MaliRuntimeMiscVertexLimit(const A5MaliCompiledProfile*p){
 if(!p||!((p->profileID>=600&&p->profileID<=606)||p->profileID==A5MaliDynamicProfileID))return A5RuntimeMaxVertices;
 return A5RuntimeMiscMaxVertices;
}
uint32_t A5MaliRuntimeVertexSpan(const A5MaliCompiledProfile*p,uint32_t count){
 if(!p||!count||count>A5MaliRuntimeMiscVertexLimit(p))return 0;
 if(p->profileID!=A5MaliDynamicProfileID)return count*48;
 if(!dynamic_textured_contract(p))return 0;
 unsigned extent=0;
 for(unsigned i=0;i<p->attributeCount;i++){
  const A5MaliCompiledVertexAttribute*a=p->attributes+i;
  unsigned end=a->offset+(a->format==31?16:8);if(end>extent)extent=end;
 }
 uint64_t bytes=(uint64_t)(count-1)*p->layouts[0].stride+extent;
 return bytes<=UINT32_MAX?(uint32_t)bytes:0;
}
static unsigned vertex_offset(const A5MaliCompiledProfile*p,unsigned index){
 static const unsigned legacy[]={0,16,24,32};
 if(p->profileID!=A5MaliDynamicProfileID)return legacy[index];
 for(unsigned i=0;i<p->attributeCount;i++)if(p->attributes[i].index==index)return p->attributes[i].offset;
 return 0; /* Only called for fields required by the validated native ABI. */
}
static unsigned dynamic_ubo_count(const A5MaliCompiledProfile*p,unsigned stage){
 unsigned count=1;
 for(unsigned i=0;i<p->resourceCount;++i){const A5MaliCompiledResource*r=p->resources+i;
  if(r->stage==stage&&r->kind==A5MaliResourceBuffer&&r->nativeIndex>=count)count=r->nativeIndex+1;
 }
 return count;
}
static int bind_buffer(const A5RuntimeMiscDraw*m,uint8_t*d,unsigned*arena,
 const A5RuntimeBuffer*b,unsigned need,uint64_t*addr,unsigned*push,unsigned*available){
 if(!need||b->offset>b->bytes||need>b->bytes-b->offset)return 0;
 if(b->cpuBytes){
  unsigned end=ARENA+A5MaliRuntimeMiscInlineCapacity(m->draw.vertexCount);
  unsigned at=(*arena+63)&~63u;if(at>end||need>end-at)return 0;
  memcpy(d+at,b->cpuBytes+b->offset,need);*arena=(at+need+63)&~63u;
  *addr=m->draw.descriptorGPUVA+at;*push=0;*available=need;return 1;
 }
 if(!span(b->gpuVA,b->bytes)||(b->gpuVA&15)||overlap(b->gpuVA,b->bytes,m->draw.descriptorGPUVA,SIZE))return 0;
 for(unsigned i=0;i<m->draw.profile->passCount;++i){const A5RuntimeImage*im=&m->colorAttachments[m->draw.profile->passes[i].logicalTarget];
  if(overlap(b->gpuVA,b->bytes,im->gpuVA,im->bytes))return 0;
 }
 unsigned folded=b->offset&~15u;*addr=b->gpuVA+folded;*push=b->offset&15u;*available=b->bytes-folded;return 1;
}
static int resources(uint8_t*d,const A5RuntimeMiscDraw*m,int home,int clear,int generic_color,int generic_textured,unsigned*outArena){
 const A5RuntimeDraw*r=&m->draw;const A5MaliCompiledProfile*p=r->profile;uint64_t VA=r->descriptorGPUVA;
 unsigned vary=varying_offset(r),varyStep=varying_step(r);
 unsigned arena=ARENA,pushes[2][31]={{0}},seen[2][31]={{0}};
 for(unsigned i=0;i<8;++i){ubo(d,VS_UBOS,i,VA+VS_SYS,576);ubo(d,FS_UBOS,i,VA+FS_SYS,576);}
 for(unsigned i=0;i<p->resourceCount;++i){const A5MaliCompiledResource*c=p->resources+i;
  if(c->stage!=A5MaliStageVertex&&c->stage!=A5MaliStageFragment)return A5RuntimeUnsupported;
  if(c->kind!=A5MaliResourceBuffer)continue;
  if(c->metalIndex>=31||c->windowOffset||(c->flags&A5MaliResourceWrite))return A5RuntimeUnsupported;
  unsigned st=c->stage==A5MaliStageFragment;
  const A5RuntimeBuffer*b=st?&r->fragmentBuffers[c->metalIndex]:&r->vertexBuffers[c->metalIndex];
  unsigned storage=!!(c->flags&A5MaliResourceStorage),need=storage?(b->offset<=b->bytes?b->bytes-b->offset:0):c->uniformBytes;
  uint64_t addr;unsigned push,available;
  if((c->flags&A5MaliResourcePadUniformTail)&&!b->cpuBytes)return A5RuntimeUnsupported;
  if(!bind_buffer(m,d,&arena,b,need,&addr,&push,&available))return A5RuntimeBounds;
  if(storage){
   if(c->sysvalOffset<96||c->sysvalOffset>336||(c->sysvalOffset&15))return A5RuntimeUnsupported;
   u64(d,(st?FS_SYS:VS_SYS)+c->sysvalOffset,addr);u32(d,(st?FS_SYS:VS_SYS)+c->sysvalOffset+8,available);
  }else{
   if(!c->nativeIndex||c->nativeIndex>=8||!c->uniformBytes||c->uniformBytes>4096)return A5RuntimeUnsupported;
   ubo(d,st?FS_UBOS:VS_UBOS,c->nativeIndex,addr,push+need);
  }
  seen[st][c->metalIndex]=1;pushes[st][c->metalIndex]=push;
 }
 for(unsigned i=0;i<p->pushFieldCount;++i){const A5MaliCompiledPushField*f=p->pushFields+i;
  if((f->stage!=A5MaliStageVertex&&f->stage!=A5MaliStageFragment)||f->bytes!=4||(f->offset&3)||f->offset>76)return A5RuntimeUnsupported;
  unsigned st=f->stage==A5MaliStageFragment,value=f->value;
  if(f->kind==A5MaliPushBindOffset){if(f->metalIndex>=31||!seen[st][f->metalIndex])return A5RuntimeUnsupported;value=pushes[st][f->metalIndex];}
  else if(f->kind!=A5MaliPushColorWriteRule)return A5RuntimeUnsupported;
  u32(d,(st?FS_SYS:VS_SYS)+f->offset,value);
 }
 /* These stock AIR vertex programs preserve Metal clip-space Y.
  * Metal2Vulkan requires a negative-height viewport at the binding boundary:
  * NDC +1 is the top row, while the texture/scissor origins stay unchanged.
  * Apply this once to all nine misc profiles; the vertex programs do not
  * independently negate their final position Y. */
 float yScale=(float)(-r->viewportHeight*.5);
 for(unsigned st=0;st<2;++st){unsigned o=st?FS_SYS:VS_SYS;
  f32(d,o+512,(float)(r->viewportWidth*.5));f32(d,o+516,yScale);f32(d,o+520,(float)((r->viewportFar-r->viewportNear)*.5));
  f32(d,o+528,(float)(r->viewportX+r->viewportWidth*.5));f32(d,o+532,(float)(r->viewportY+r->viewportHeight*.5));f32(d,o+536,(float)((r->viewportFar+r->viewportNear)*.5));
 }
 if(home||generic_color||generic_textured){
  uint64_t vertex;unsigned push,available;
  unsigned vertexBytes=A5MaliRuntimeVertexSpan(p,r->vertexCount);
  unsigned stride=p->profileID==A5MaliDynamicProfileID?p->layouts[0].stride:48;
  if(!vertexBytes||!bind_buffer(m,d,&arena,&r->vertexBuffers[1],vertexBytes,&vertex,&push,&available))return A5RuntimeBounds;
  vertex+=push;unsigned low=(unsigned)(vertex&63);vertex&=~UINT64_C(63);
  attr(d,ATTRS,0,p->attributes[0].format==29?MALI_RG32F:MALI_RGBA32F,
       p->attributes[0].format==29?RG_SWIZZLE:0x688,low+vertex_offset(p,0));
  if(generic_color||(p->flags&A5MaliProfileVertexColorOnly))attr(d,ATTRS+8,0,MALI_RGBA16F,0x688,low+vertex_offset(p,3));
  else{attr(d,ATTRS+8,0,MALI_RG32F,RG_SWIZZLE,low+vertex_offset(p,1));
   if(p->flags&A5MaliProfileVertexTwoUV){
    attr(d,ATTRS+16,0,MALI_RG32F,RG_SWIZZLE,low+vertex_offset(p,2));
    if(!(p->flags&A5MaliProfileVertexNoColor))attr(d,ATTRS+24,0,MALI_RGBA16F,0x688,low+vertex_offset(p,3));
   }
   else attr(d,ATTRS+16,0,MALI_RGBA16F,0x688,low+vertex_offset(p,3));
  }
  buf(d,ATTR_BUFS,vertex,stride,vertexBytes+low);
  if(generic_textured){int rc=(p->profileID==A5MaliDynamicProfileID&&!dynamic_legacy_texture(m))?dynamic_images(d,m):textured_image(d,m);if(rc)return rc;}
  if(home)for(unsigned t=0;t<2;++t){const A5RuntimeImage*im=&m->fragmentTextures[t+3];unsigned tex=t?TEX1:TEX0;
   if(!valid_image(im)||im->metalPixelFormat!=80)return A5RuntimeUnsupported;
   for(unsigned i=0;i<p->passCount;++i){const A5RuntimeImage*dest=&m->colorAttachments[p->passes[i].logicalTarget];
    if(overlap(im->gpuVA,im->bytes,dest->gpuVA,dest->bytes))return A5RuntimeUnsupported;
   }
   if(overlap(im->gpuVA,im->bytes,VA,SIZE))return A5RuntimeUnsupported;
   pan_pack((struct mali_texture_packed*)(d+tex),TEXTURE,c){c.width=im->width;c.height=im->height;c.array_size=1;c.levels=1;c.format=(MALI_RGBA8_UNORM<<12)|0x60a;c.dimension=MALI_TEXTURE_DIMENSION_2D;c.texel_ordering=MALI_TEXTURE_LAYOUT_LINEAR;c.swizzle=0x688;}
   pan_pack((struct mali_surface_with_stride_packed*)(d+tex+32),SURFACE_WITH_STRIDE,c){c.pointer=im->gpuVA;c.row_stride=im->rowBytes;c.surface_stride=im->rowBytes*im->height;}
   u64(d,TEX_TABLE+t*8,VA+tex);
   /* Exact AIR constexpr sampler: linear, normalized clamp-to-edge, LOD0..0.25. */
   pan_pack((struct mali_sampler_packed*)(d+SAMPLERS+t*32),SAMPLER,c){c.normalized_coordinates=true;c.seamless_cube_map=false;c.minify_nearest=false;c.magnify_nearest=false;c.maximum_lod=.25f;}
   unsigned q=FS_SYS+352+32*t;u32(d,q,1);u32(d,q+4,im->width);u32(d,q+8,im->height);f32(d,q+20,.25f);
  }
 }else{
  pan_pack((struct mali_attribute_vertex_id_packed*)(d+ATTR_BUFS),ATTRIBUTE_VERTEX_ID,c){c.divisor_r=31;c.divisor_p=4;}
  pan_pack((struct mali_attribute_instance_id_packed*)(d+ATTR_BUFS+32),ATTRIBUTE_INSTANCE_ID,c){c.divisor_p=0x7fffffff;c.divisor_r=31;c.divisor_e=1;}
  attr(d,ATTRS+16*8,0,MALI_R32UI,R_SWIZZLE,0);attr(d,ATTRS+17*8,2,MALI_R32UI,R_SWIZZLE,0);
 }
 attr(d,VS_VARY,0,MALI_SNAP_4,0x688,0);buf(d,VS_VARY_BUFS,VA+position_offset(r),16,r->vertexCount*16);
 attr(d,VS_VARY+8,1,MALI_R16F,R_SWIZZLE,0);buf(d,VS_VARY_BUFS+16,VA+point_size_offset(r),2,r->vertexCount*2);
 if((home||generic_textured)&&!(p->flags&A5MaliProfileVertexColorOnly)){
  attr(d,VS_VARY+16,2,MALI_RGBA32UI,0x688,0);buf(d,VS_VARY_BUFS+32,VA+vary,16,r->vertexCount*16);
  attr(d,VS_VARY+24,3,MALI_RG32UI,RG_SWIZZLE,0);buf(d,VS_VARY_BUFS+48,VA+vary+varyStep,8,r->vertexCount*8);
  if(generic_textured){
   /* Textured VS: hardware VAR0 is UV, VAR1 is colour; FS reads VAR0. */
   attr(d,VS_VARY+16,2,MALI_RG32UI,RG_SWIZZLE,0);
   buf(d,VS_VARY_BUFS+32,VA+vary,8,r->vertexCount*8);
   unsigned colorData=vary+((p->flags&A5MaliProfileVertexTwoUV)?2*varyStep:varyStep);
   if(p->flags&A5MaliProfileVertexTwoUV){
    attr(d,VS_VARY+24,3,MALI_RG32UI,RG_SWIZZLE,0);
    buf(d,VS_VARY_BUFS+48,VA+vary+varyStep,8,r->vertexCount*8);
    if(!(p->flags&A5MaliProfileVertexNoColor)){
     attr(d,VS_VARY+32,4,MALI_RGBA32UI,0x688,0);
     buf(d,VS_VARY_BUFS+64,VA+colorData,16,r->vertexCount*16);
    }
   }else{
    attr(d,VS_VARY+24,3,MALI_RGBA32UI,0x688,0);
    buf(d,VS_VARY_BUFS+48,VA+colorData,16,r->vertexCount*16);
   }
   if(!(p->flags&(A5MaliProfileFragmentNoInputs|A5MaliProfileFragmentColorOnly))){
    attr(d,FS_VARY,0,MALI_RG32F,RG_SWIZZLE,0);
    buf(d,FS_VARY_BUFS,VA+vary,8,r->vertexCount*8);
   }
   unsigned colorSlot=(p->flags&A5MaliProfileFragmentColorOnly)?0:(p->flags&A5MaliProfileFragmentTwoUV)?2:1;
   if(p->flags&A5MaliProfileFragmentTwoUV){
    attr(d,FS_VARY+8,1,MALI_RG32F,RG_SWIZZLE,0);
    buf(d,FS_VARY_BUFS+16,VA+vary+varyStep,8,r->vertexCount*8);
   }
   if(p->profileID==604||(p->flags&A5MaliProfileDynamicColorVarying)){
    attr(d,FS_VARY+colorSlot*8,colorSlot,MALI_RGBA32F,0x688,0);
    buf(d,FS_VARY_BUFS+colorSlot*16,VA+colorData,16,r->vertexCount*16);
   }
   if(p->flags&A5MaliProfileFragmentPosition){
    unsigned positionSlot=(p->flags&A5MaliProfileFragmentTwoUV)?3:2;
    attr(d,FS_VARY+positionSlot*8,positionSlot,MALI_RGBA32F,0x688,0);
    pan_pack((struct mali_attribute_buffer_packed*)(d+FS_VARY_BUFS+positionSlot*16),ATTRIBUTE_BUFFER,c){
     c.type=0;c.special=MALI_ATTRIBUTE_SPECIAL_FRAG_COORD;
    }
   }
  }else{
   attr(d,FS_VARY,0,MALI_RG32F,RG_SWIZZLE,0);
   buf(d,FS_VARY_BUFS,VA+vary+varyStep,8,r->vertexCount*8);
  }
 }else if(generic_color||(p->flags&A5MaliProfileVertexColorOnly)){
  attr(d,VS_VARY+16,2,MALI_RGBA32UI,0x688,0);
  buf(d,VS_VARY_BUFS+32,VA+vary,16,r->vertexCount*16);
  if(!(p->flags&A5MaliProfileFragmentNoInputs)){
   attr(d,FS_VARY,0,MALI_RGBA32F,0x688,0);
   buf(d,FS_VARY_BUFS,VA+vary,16,r->vertexCount*16);
  }
 }else if(!clear){
  for(unsigned i=0;i<5;++i){unsigned off=VARY_DATA+i*0x1000,stride=i?4:8;
   attr(d,VS_VARY+(i+2)*8,i+2,i?MALI_R32UI:MALI_RG32UI,i?R_SWIZZLE:RG_SWIZZLE,0);buf(d,VS_VARY_BUFS+(i+2)*16,VA+off,stride,r->vertexCount*stride);
   attr(d,FS_VARY+i*8,i,i?MALI_R32UI:MALI_RG32F,i?R_SWIZZLE:RG_SWIZZLE,0);buf(d,FS_VARY_BUFS+i*16,VA+off,stride,r->vertexCount*stride);
  }
 }
 *outArena=arena;
 return A5RuntimeOK;
}

/* The index values are validated on the immutable commit-time snapshot. Mali
 * JM consumes the arena copy directly; no external index GPU allocation or
 * unchecked buffer handle enters the native queue. The VS runs vertices
 * 0..maxIndex and the tiler indexes its position/varying arrays directly. */
static int index_data(uint8_t*d,const A5RuntimeDraw*r,unsigned arena,uint64_t*gpuVA){
 *gpuVA=0;
 if(!r->indexCount)return r->indexSize?A5RuntimeUnsupported:A5RuntimeOK;
 if((r->indexSize!=2&&r->indexSize!=4)||r->indexCount<2||
    r->indexCount>A5RuntimeMaxIndices)return A5RuntimeUnsupported;
 const A5RuntimeBuffer*b=&r->indexBuffer;
 unsigned need=r->indexCount*r->indexSize;
 if(!b->cpuBytes||b->offset>b->bytes||need>b->bytes-b->offset||
    (b->offset&(r->indexSize-1)))return A5RuntimeBounds;
 uint32_t max=0;
 for(unsigned i=0;i<r->indexCount;++i){
  uint32_t index=0;
  memcpy(&index,b->cpuBytes+b->offset+i*r->indexSize,r->indexSize);
  if(index>=r->vertexCount)return A5RuntimeBounds;
  if(index>max)max=index;
 }
 if(max+1!=r->vertexCount)return A5RuntimeUnsupported;
 unsigned at=(arena+63)&~63u;
 unsigned end=ARENA+A5MaliRuntimeMiscInlineCapacity(r->vertexCount);
 if(at>end||need>end-at)return A5RuntimeBounds;
 memcpy(d+at,b->cpuBytes+b->offset,need);
 *gpuVA=r->descriptorGPUVA+at;
 return A5RuntimeOK;
}

static void jobs(uint8_t*d,uint64_t VA,const A5RuntimeDraw*r,uint64_t indexVA){
 pan_pack((struct mali_job_header_packed*)d,JOB_HEADER,c){c.type=MALI_JOB_TYPE_VERTEX;c.index=1;c.next=VA+0x100;}
 pan_pack((struct mali_invocation_packed*)(d+32),INVOCATION,c){c.invocations=r->vertexCount-1;c.workgroups_z_shift=32;c.thread_group_split=2;}
 pan_pack((struct mali_compute_job_parameters_packed*)(d+MALI_COMPUTE_JOB_SECTION_PARAMETERS_OFFSET),COMPUTE_JOB_PARAMETERS,c){c.job_task_split=5;}
 pan_pack((struct mali_draw_packed*)(d+64),DRAW,c){c.state=VA+VS_RSD;c.attributes=VA+ATTRS;c.attribute_buffers=VA+ATTR_BUFS;c.uniform_buffers=VA+VS_UBOS;c.varyings=VA+VS_VARY;c.varying_buffers=VA+VS_VARY_BUFS;c.thread_storage=VA+FB;}
 pan_pack((struct mali_job_header_packed*)(d+0x100),JOB_HEADER,c){c.type=MALI_JOB_TYPE_TILER;c.index=2;c.dependency_1=1;c.enable_texture_mapper=true;}
 pan_pack((struct mali_invocation_packed*)(d+0x120),INVOCATION,c){c.invocations=r->vertexCount-1;c.workgroups_z_shift=32;c.thread_group_split=2;}
 pan_pack((struct mali_primitive_packed*)(d+0x128),PRIMITIVE,c){
  c.draw_mode=r->primitive==A5RuntimeLine?MALI_DRAW_MODE_LINES:
   r->primitive==A5RuntimeLineStrip?MALI_DRAW_MODE_LINE_STRIP:
   r->primitive==A5RuntimeTriangle?MALI_DRAW_MODE_TRIANGLES:MALI_DRAW_MODE_TRIANGLE_STRIP;
  c.index_count=r->indexCount?r->indexCount:r->vertexCount;
  c.index_type=r->indexCount?(r->indexSize==2?MALI_INDEX_TYPE_UINT16:MALI_INDEX_TYPE_UINT32):MALI_INDEX_TYPE_NONE;
  c.indices=indexVA;c.job_task_split=6;
 }
 /* Released Panfrost selects the line provoking vertex in DRAW rather than
  * PRIMITIVE; triangles keep their existing zero/default selection. */
 pan_pack((struct mali_draw_packed*)(d+0x140),DRAW,c){c.position=VA+position_offset(r);c.flat_shading_vertex=r->primitive==A5RuntimeLine||r->primitive==A5RuntimeLineStrip;c.viewport=VA+VIEWPORT;c.varyings=VA+FS_VARY;c.varying_buffers=VA+FS_VARY_BUFS;c.uniform_buffers=VA+FS_UBOS;c.textures=VA+TEX_TABLE;c.samplers=VA+SAMPLERS;c.state=VA+FS_RSD;c.fbd=VA+FB;}
 pan_pack((struct mali_primitive_size_packed*)(d+0x1b8),PRIMITIVE_SIZE,c){c.fixed_sized=1;}
 pan_pack((struct mali_viewport_packed*)(d+VIEWPORT),VIEWPORT,c){c.scissor_minimum_x=r->scissorX;c.scissor_minimum_y=r->scissorY;c.scissor_maximum_x=r->scissorX+r->scissorWidth-1;c.scissor_maximum_y=r->scissorY+r->scissorHeight-1;}
 pan_pack((struct mali_job_header_packed*)(d+0x200),JOB_HEADER,c){c.type=MALI_JOB_TYPE_FRAGMENT;c.index=3;c.enable_texture_mapper=true;}
 pan_pack((struct mali_fragment_job_payload_packed*)(d+0x220),FRAGMENT_JOB_PAYLOAD,c){c.bound_min_x=r->scissorX/16;c.bound_min_y=r->scissorY/16;c.bound_max_x=(r->scissorX+r->scissorWidth-1)/16;c.bound_max_y=(r->scissorY+r->scissorHeight-1)/16;c.framebuffer=VA+FB;}
}
static int encode(const A5RuntimeMiscDraw*m,uint8_t*d){
 const A5RuntimeDraw*r=&m->draw;const A5MaliCompiledProfile*p=r->profile;
 if(!p||!(p->profileID==200||p->profileID==202||p->profileID==204||p->profileID==206||p->profileID==207||p->profileID==600||p->profileID==601||p->profileID==602||p->profileID==603||p->profileID==604||p->profileID==605||p->profileID==606||p->profileID==A5MaliDynamicProfileID)||
  p->passCount<1||p->passCount>2||!p->passes||m->passIndex>=p->passCount||p->resourceCount>16||p->pushFieldCount>16)return A5RuntimeUnsupported;
 const A5MaliCompiledPass*pass=p->passes+m->passIndex;
 int home=p->profileID==206,clear=p->profileID==207,generic_color=p->profileID==600||p->profileID==601||p->profileID==602;
 int dynamic=p->profileID==A5MaliDynamicProfileID;
 int generic_textured=p->profileID==603||p->profileID==604||p->profileID==605||p->profileID==606||dynamic;
 if(generic_color&&!generic_color_contract(p))return A5RuntimeUnsupported;
 if(generic_textured&&!(dynamic?dynamic_textured_contract(p):generic_textured_contract(p)))return A5RuntimeUnsupported;
 if(pass->logicalTarget>=2||p->passCount!=1||pass->logicalTarget!=(clear?1u:0u))return A5RuntimeUnsupported;
 if(!span(r->descriptorGPUVA,SIZE)||(r->descriptorGPUVA&4095))return A5RuntimeBounds;
 for(unsigned i=0;i<p->passCount;++i){unsigned target=p->passes[i].logicalTarget;if(target>=2)return A5RuntimeUnsupported;
  const A5RuntimeImage*im=&m->colorAttachments[target];
  if(!valid_image(im)||im->metalPixelFormat!=p->colorFormats[target]||overlap(im->gpuVA,im->bytes,r->descriptorGPUVA,SIZE))return A5RuntimeBounds;
  for(unsigned j=0;j<i;++j){const A5RuntimeImage*other=&m->colorAttachments[p->passes[j].logicalTarget];
   if(overlap(im->gpuVA,im->bytes,other->gpuVA,other->bytes)||im->width!=other->width||im->height!=other->height)return A5RuntimeUnsupported;
  }
 }
 const A5RuntimeImage*out=&m->colorAttachments[pass->logicalTarget];
 unsigned drawCount=r->indexCount?r->indexCount:r->vertexCount;
 unsigned minimum=(r->primitive==A5RuntimeLine||r->primitive==A5RuntimeLineStrip)?2:3;
 if(r->vertexStart||!r->vertexCount||drawCount<minimum||
   r->vertexCount>A5MaliRuntimeMiscVertexLimit(p)||
   (r->indexCount&&p->profileID!=602&&!generic_textured)||
   (!r->indexCount&&r->indexSize)||r->indexCount>A5RuntimeMaxIndices||
   (r->primitive!=A5RuntimeLine&&r->primitive!=A5RuntimeLineStrip&&r->primitive!=A5RuntimeTriangle&&r->primitive!=A5RuntimeTriangleStrip)||
   (r->primitive==A5RuntimeLine&&drawCount%2)||
   (r->primitive==A5RuntimeTriangle&&drawCount%3)||r->blend>A5RuntimeBlendState||
   ((r->blend==A5RuntimeBlendState)!=!!(p->flags&A5MaliProfileRenderState))||
   (r->blend&&r->blend!=A5RuntimeBlendState&&((r->blend==A5RuntimeBlendScreen)!=!!(p->flags&A5MaliProfileScreenBlend)))||
   (r->blend&&(!(p->flags&A5MaliProfileSourceOverBlend)||
     (out->metalPixelFormat==115&&!(p->flags&A5MaliProfileInlineSourceOver))))||
   ((p->flags&A5MaliProfileInlineSourceOver)&&r->blend!=A5RuntimeBlendPremultipliedSourceOver))return A5RuntimeUnsupported;
 if(generic_color&&!(p->flags&A5MaliProfileSourceOverBlend)&&r->blend!=A5RuntimeBlendCopy)return A5RuntimeUnsupported;
 if(!isfinite(r->viewportX)||!isfinite(r->viewportY)||!isfinite(r->viewportWidth)||!isfinite(r->viewportHeight)||
   !isfinite(r->viewportNear)||!isfinite(r->viewportFar)||r->viewportWidth<=0||r->viewportHeight<=0||
   r->viewportX<0||r->viewportY<0||r->viewportWidth>4096-r->viewportX||r->viewportHeight>4096-r->viewportY||
   r->viewportNear<0||r->viewportNear>r->viewportFar||r->viewportFar>1)return A5RuntimeUnsupported;
 if(!r->scissorWidth||!r->scissorHeight||r->scissorX>=out->width||r->scissorY>=out->height||
   r->scissorWidth>out->width-r->scissorX||r->scissorHeight>out->height-r->scissorY)return A5RuntimeBounds;
 const A5MaliCompiledShader*vs=&pass->vertex,*fs=&pass->fragment;
 if(!vs->bytes||!fs->bytes||!vs->byteCount||vs->byteCount>(dynamic?0x2000u:0x1000u)||!fs->byteCount||fs->byteCount>(dynamic&&(p->flags&A5MaliProfileShaderAnisotropy)?0x4000u:dynamic?0x2000u:0x1000u)||
   (vs->byteCount&15)||(fs->byteCount&15)||(dynamic?(!shader_tag(vs->firstTag)||!shader_tag(fs->firstTag)):vs->firstTag!=5||fs->firstTag!=5)||vs->tlsBytes||vs->wlsBytes||
   fs->tlsBytes||fs->wlsBytes||!vs->workRegisters||vs->workRegisters>16||!fs->workRegisters||fs->workRegisters>16)return A5RuntimeUnsupported;
 if(dynamic&&(((vs->bytes[0]&15)!=vs->firstTag)||((fs->bytes[0]&15)!=fs->firstTag)))return A5RuntimeUnsupported;
 unsigned fragmentCode=dynamic&&fs->byteCount>0x2000?BIG_FS_CODE:FS_CODE;
 memcpy(d+VS_CODE,vs->bytes,vs->byteCount);memcpy(d+fragmentCode,fs->bytes,fs->byteCount);
 unsigned fmt=out->metalPixelFormat==115?2:out->metalPixelFormat==10?1:out->metalPixelFormat==30?3:out->metalPixelFormat==43?4:0;
 framebuffer(d,r->descriptorGPUVA,fmt,out);renderer(d,r->descriptorGPUVA,home,clear,generic_color,generic_textured,p->profileID==604||!!(p->flags&A5MaliProfileDynamicColorVarying),vs->workRegisters,fs->workRegisters,
  p->flags&A5MaliProfileInlineSourceOver?0:r->blend);
 if(r->blend==A5RuntimeBlendState){
  A5MaliBlendPlan plan=A5MaliLowerRenderState(&p->attachmentContracts[1].attachments[0]);
  if(p->flags&A5MaliProfileShaderBlend){
   if(plan.route!=A5MaliStateNeedsShader)return A5RuntimeUnsupported;
   /* NIR already applied the complete equation and mask. Hardware only stores
    * the result; applying the API equation here would blend twice. */
   A5MaliCompiledAttachmentState copy={15,0,0,0,1,0,1,0};
   plan=A5MaliLowerRenderState(&copy);plan.loadDestination=1;
  }else if(plan.route!=A5MaliStateFixed)return A5RuntimeUnsupported;
  struct MALI_RENDERER_STATE state;
  MALI_RENDERER_STATE_unpack((const struct mali_renderer_state_packed*)(d+FS_RSD),&state);
  /* RSD overlay: blend_shader aliases the packed equation. Clear the
   * decoded pointer arm before replacing equation bits, or old bits OR in. */
  state.blend_shader=0;
  state.multisample_misc.load_destination=plan.loadDestination;
  state.blend_equation.color_mask=plan.writeMask;
  state.blend_equation.rgb=(struct MALI_BLEND_FUNCTION){.a=plan.rgb.a,.b=plan.rgb.b,.c=plan.rgb.c,
   .negate_a=plan.rgb.negateA,.negate_b=plan.rgb.negateB,.invert_c=plan.rgb.invertC};
  state.blend_equation.alpha=(struct MALI_BLEND_FUNCTION){.a=plan.alpha.a,.b=plan.alpha.b,.c=plan.alpha.c,
   .negate_a=plan.alpha.negateA,.negate_b=plan.alpha.negateB,.invert_c=plan.alpha.invertC};
  MALI_RENDERER_STATE_pack((struct mali_renderer_state_packed*)(d+FS_RSD),&state);
 }

 if(dynamic){
  struct MALI_RENDERER_STATE rs;
  MALI_RENDERER_STATE_unpack((const struct mali_renderer_state_packed*)(d+VS_RSD),&rs);
  rs.shader.shader=r->descriptorGPUVA+VS_CODE+vs->firstTag;
  if(p->flags&A5MaliProfileVertexColorOnly){rs.shader.attribute_count=2;rs.shader.varying_count=3;}
  if(p->flags&A5MaliProfileVertexTwoUV){rs.shader.attribute_count=4;rs.shader.varying_count=5;}
  if(p->flags&A5MaliProfileVertexNoColor){rs.shader.attribute_count=3;rs.shader.varying_count=4;}
  rs.properties.uniform_buffer_count=dynamic_ubo_count(p,A5MaliStageVertex);
  MALI_RENDERER_STATE_pack((struct mali_renderer_state_packed*)(d+VS_RSD),&rs);
  MALI_RENDERER_STATE_unpack((const struct mali_renderer_state_packed*)(d+FS_RSD),&rs);
  rs.shader.shader=r->descriptorGPUVA+fragmentCode+fs->firstTag;
  rs.properties.uniform_buffer_count=dynamic_ubo_count(p,A5MaliStageFragment);
  unsigned count=0;for(unsigned i=0;i<p->resourceCount;i++){
   const A5MaliCompiledResource*r=p->resources+i;
   if(r->kind==A5MaliResourceTexture&&r->nativeIndex>=count)count=r->nativeIndex+1;
  }
  rs.shader.texture_count=count;rs.shader.sampler_count=count;
  if(p->flags&A5MaliProfileFragmentTwoUV)rs.shader.varying_count=(p->flags&A5MaliProfileDynamicColorVarying)?3:2;
  if(p->flags&A5MaliProfileFragmentPosition)rs.shader.varying_count=(p->flags&A5MaliProfileFragmentTwoUV)?4:3;
  if(p->flags&A5MaliProfileFragmentNoInputs)rs.shader.varying_count=0;
  if(p->flags&A5MaliProfileFragmentColorOnly)rs.shader.varying_count=1;
  MALI_RENDERER_STATE_pack((struct mali_renderer_state_packed*)(d+FS_RSD),&rs);
 }
 if(p->flags&(A5MaliProfileInlineSourceOver|A5MaliProfileFramebufferFetch|A5MaliProfileShaderBlend)){
  /* Inline blend shader reads the preloaded tilebuffer. Fixed-function RSD
   * remains copy, never applies the equation a second time. For general
   * framebuffer fetch preserve the actual pipeline blend equation and turn
   * on tilebuffer destination loads even when fixed-function blending is off. */
  struct MALI_RENDERER_STATE rs;MALI_RENDERER_STATE_unpack((const struct mali_renderer_state_packed*)(d+FS_RSD),&rs);
  rs.multisample_misc.load_destination=true;MALI_RENDERER_STATE_pack((struct mali_renderer_state_packed*)(d+FS_RSD),&rs);
 }
 unsigned arena=0;
 int rc=resources(d,m,home,clear,generic_color,generic_textured,&arena);if(rc)return rc;
 if(p->flags&A5MaliProfileShaderBlend)for(unsigned i=0;i<4;i++){
  if(!isfinite(m->blendColor[i]))return A5RuntimeBounds;
  f32(d,FS_SYS+480+4*i,m->blendColor[i]);
 }
 uint64_t indexVA=0;rc=index_data(d,r,arena,&indexVA);if(rc)return rc;
 jobs(d,r->descriptorGPUVA,r,indexVA);
 if(dynamic&&!dynamic_legacy_texture(m)){
  struct MALI_DRAW draw;MALI_DRAW_unpack((const struct mali_draw_packed*)(d+0x140),&draw);
  if(p->flags&A5MaliProfileFragmentNoInputs){
   draw.textures=0;draw.samplers=0;draw.varyings=0;draw.varying_buffers=0;
  }else if(p->flags&(A5MaliProfileFragmentColorOnly|A5MaliProfileFragmentNoTextures)){
   draw.textures=0;draw.samplers=0;
  }else{
   draw.textures=r->descriptorGPUVA+DYNAMIC_TEX_TABLE;draw.samplers=r->descriptorGPUVA+DYNAMIC_SAMPLERS;
  }
  MALI_DRAW_pack((struct mali_draw_packed*)(d+0x140),&draw);
 }
 return a5_runtime_preload(d,r->descriptorGPUVA,&m->colorAttachments[pass->logicalTarget]);
}
int A5MaliEncodeRuntimeMiscPass(const A5RuntimeMiscDraw*m,void*out,size_t n){
 if(!out||n!=SIZE)return A5RuntimeInvalid;memset(out,0,n);
 int rc=m?encode(m,out):A5RuntimeInvalid;if(rc)memset(out,0,n);return rc;
}
