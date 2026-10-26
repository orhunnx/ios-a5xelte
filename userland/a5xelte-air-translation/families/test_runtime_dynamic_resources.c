/* SPDX-License-Identifier: MIT
 * Structural runtime ABI tests. Fake code bytes validate descriptors only;
 * translated fetch/pixel fixtures must independently pass on physical GPU.
 */
#define PAN_ARCH 4
#include "runtime_misc_encode.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "genxml/v4_pack.h"
static uint8_t descriptor[A5RuntimeJobBytes];
static uint8_t vertices[4*48],matrix[64],uvTransform[16],bias[8];
static int zeroed(void){for(size_t i=0;i<sizeof(descriptor);++i)if(descriptor[i])return 0;return 1;}
int main(void){
 static uint8_t vs[2192]={5},fs[880]={5};
 A5MaliCompiledPass pass={65536,0,
  {vs,2192,5,8,0,0,"e0c51d2171b28c891677cdb1f1c98032bee0f03bb64af694a8321d711159fc96"},
  {fs,880,5,5,0,0,"e4cf4d31a87bde096cc7cc57a12818f79296e3998d22d9c6c5139a9887f30047"}};
 A5MaliCompiledResource resources[9]={
  {1,1,2,0,1,1,0,64,0,0},{1,1,3,1,2,1,0,16,0,4},
  {2,1,2,3,4,1,0,8,0,68},{2,2,3,5,0,1,0,0,0,0},
  {2,3,0,5,0,1,0,0,0,0}
 };
 A5MaliCompiledPushField push[]={
  {1,1,2,0,4,0},{1,1,3,4,4,0},{2,1,2,68,4,0},
  {2,2,0,72,4,0x2222}
 };
 A5MaliCompiledVertexAttribute attrs[]={
  {0,31,0,1},{1,29,16,1},{2,29,24,1},{3,27,32,1}};
 A5MaliCompiledVertexLayout layout={1,48,1,1};
 A5MaliCompiledAttachmentContract attachment[2]={0};
 for(unsigned c=0;c<2;++c)for(unsigned i=0;i<8;++i){
  attachment[c].attachments[i].writeMask=15;
  attachment[c].attachments[i].sourceRGB=1;
  attachment[c].attachments[i].sourceAlpha=1;
 }
 attachment[1].attachments[0].blendEnabled=1;
 attachment[1].attachments[0].destinationRGB=5;
 attachment[1].attachments[0].destinationAlpha=5;
 A5MaliCompiledProfile p={0};p.profileID=A5MaliDynamicProfileID;p.vertexName="fixed_vert_lph_spc";
 p.fragmentName="fixed_frag_lph_cph";p.colorFormats[0]=80;
 p.flags=A5MaliProfileSourceOverBlend|A5MaliProfileDynamicStages;
 p.passes=&pass;p.passCount=1;p.resources=resources;p.resourceCount=5;
 p.pushFields=push;p.pushFieldCount=4;p.attributes=attrs;p.attributeCount=4;
 p.layouts=&layout;p.layoutCount=1;
 p.attachmentContracts=attachment;p.attachmentContractCount=2;
 A5RuntimeMiscDraw m={0};m.draw.profile=&p;m.draw.descriptorGPUVA=0x12000000;
 m.draw.vertexCount=4;m.draw.primitive=A5RuntimeTriangleStrip;
 m.draw.viewportWidth=m.draw.viewportHeight=32;m.draw.viewportFar=1;
 m.draw.scissorWidth=m.draw.scissorHeight=32;
 m.draw.vertexBuffers[1]=(A5RuntimeBuffer){0,sizeof(vertices),0,vertices};
 m.draw.vertexBuffers[2]=(A5RuntimeBuffer){0,sizeof(matrix),0,matrix};
 m.draw.vertexBuffers[3]=(A5RuntimeBuffer){0,sizeof(uvTransform),0,uvTransform};
 m.draw.fragmentBuffers[2]=(A5RuntimeBuffer){0,sizeof(bias),0,bias};
 m.colorAttachments[0]=(A5RuntimeImage){0x22000000,4096,32,32,128,80};
 m.fragmentTextures[3]=(A5RuntimeImage){0x23000000,1024,16,16,64,80};
 m.fragmentSamplers[0]=(A5RuntimeSampler){1,A5RuntimeSamplerLinear,
  A5RuntimeSamplerNearest,A5RuntimeSamplerMipNone,
  A5RuntimeSamplerClampEdge,A5RuntimeSamplerClampEdge,
  A5RuntimeSamplerClampEdge,1,1,0,0,1000};

 assert(A5MaliDynamicRuntimeProfileSupported(&p));
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 /* RGBA source and BGRA target: red and blue cannot be aliased. Both
  * the compact Texture3 and reflected multi-resource descriptor paths count. */
 for(unsigned rgba=0;rgba<2;rgba++){
  m.fragmentTextures[3].metalPixelFormat=rgba?70:80;
  assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
  pan_unpack((struct mali_texture_packed*)(descriptor+0x600),TEXTURE,order);
  assert((order.format>>12)==MALI_RGBA8_UNORM&&(order.format&0xfff)==(rgba?0x688:0x60a));
  const unsigned char texel[4]={0x19,0x73,0xe1,0x85};
  assert(texel[(order.format&7)]==(rgba?0x19:0xe1));
  assert(texel[((order.format>>6)&7)]==(rgba?0xe1:0x19));
 }
 m.fragmentTextures[3].metalPixelFormat=80;
 /* Extra resource: a separate half4 noise/LUT texture with a different Metal
  * sampler slot. The emitter must use reflected indices, not Texture3/S0. */
 resources[5]=(A5MaliCompiledResource){2,2,7,6,1,1,0,0,0,0};
 resources[6]=(A5MaliCompiledResource){2,3,2,6,1,1,0,0,0,0};
 p.resourceCount=7;
 m.fragmentTextures[7]=(A5RuntimeImage){0x24000000,2048,256,1,2048,115};
 m.fragmentSamplers[2]=m.fragmentSamplers[0];
 m.fragmentSamplers[2].minFilter=A5RuntimeSamplerNearest;
 assert(A5MaliDynamicRuntimeProfileSupported(&p));
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,rs);
 pan_unpack((struct mali_draw_packed*)(descriptor+0x140),DRAW,draw);
 assert(rs.shader.texture_count==2&&rs.shader.sampler_count==2);
 assert(draw.textures==m.draw.descriptorGPUVA+0x4100&&draw.samplers==m.draw.descriptorGPUVA+0x4140);
 pan_unpack((struct mali_texture_packed*)(descriptor+0x4040),TEXTURE,tex);
 pan_unpack((struct mali_surface_with_stride_packed*)(descriptor+0x4060),SURFACE_WITH_STRIDE,surf);
 pan_unpack((struct mali_sampler_packed*)(descriptor+0x4160),SAMPLER,sampler);
 assert(tex.width==256&&tex.height==1&&(tex.format>>12)==MALI_RGBA16F);
 assert(surf.pointer==m.fragmentTextures[7].gpuVA&&surf.row_stride==2048);
 assert(sampler.minify_nearest&&sampler.magnify_nearest&&sampler.normalized_coordinates);
 for(unsigned rgba=0;rgba<2;rgba++){
  m.fragmentTextures[3].metalPixelFormat=rgba?70:80;
  assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
  pan_unpack((struct mali_texture_packed*)(descriptor+0x4000),TEXTURE,expanded);
  assert((expanded.format>>12)==MALI_RGBA8_UNORM&&(expanded.format&0xfff)==(rgba?0x688:0x60a));
 }
 m.fragmentTextures[3].metalPixelFormat=80;
 /* Native slot holes are permitted only where compiler liveness omitted a
  * descriptor; counts cover the highest live slot and the hole remains zero. */
 resources[5].nativeIndex=resources[6].nativeIndex=3;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,sparse);
 assert(sparse.shader.texture_count==4&&sparse.shader.sampler_count==4);
 uint64_t hole;memcpy(&hole,descriptor+0x4108,8);assert(!hole);
 resources[5].nativeIndex=resources[6].nativeIndex=1;
 resources[6].bindingIndex=9;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 resources[6].bindingIndex=6;
 resources[5].nativeIndex=resources[6].nativeIndex=4;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));
 resources[5].nativeIndex=resources[6].nativeIndex=1;
 resources[7]=resources[5];p.resourceCount=8;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));p.resourceCount=7;
 /* Independent constexpr repeat state never consumes a mutable Metal
  * sampler slot. Its actual normalized/repeat/filter/LOD fields are encoded. */
 A5MaliCompiledSampler immutable={1,0,0,0,1,1,1,1,0,0.25f};
 resources[6].flags=A5MaliResourceRead|A5MaliResourceImmutableSampler;
 resources[6].metalIndex=31;p.immutableSamplers=&immutable;p.immutableSamplerCount=1;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_sampler_packed*)(descriptor+0x4160),SAMPLER,constant);
 assert(constant.wrap_mode_s==MALI_WRAP_MODE_REPEAT&&constant.wrap_mode_t==MALI_WRAP_MODE_REPEAT&&
        constant.wrap_mode_r==MALI_WRAP_MODE_REPEAT&&constant.maximum_lod==0.25f&&constant.minify_nearest);
 immutable.lodMaxClamp=16;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));immutable.lodMaxClamp=0.25f;
 resources[2].flags=A5MaliResourceRead|A5MaliResourcePadUniformTail;resources[2].uniformBytes=2;
 m.draw.fragmentBuffers[2].bytes=2;bias[0]=0xa5;bias[1]=0x5a;bias[2]=0xef;bias[3]=0xef;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_uniform_buffer_packed*)(descriptor+0x760),UNIFORM_BUFFER,padded);
 unsigned at=(unsigned)(padded.pointer-m.draw.descriptorGPUVA);
 assert(at>=0x20000&&at<0x30000&&descriptor[at]==0xa5&&descriptor[at+1]==0x5a&&
        descriptor[at+2]==0&&descriptor[at+3]==0);
 m.draw.fragmentBuffers[2].cpuBytes=NULL;m.draw.fragmentBuffers[2].gpuVA=0x26000000;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 m.draw.fragmentBuffers[2].cpuBytes=bias;m.draw.fragmentBuffers[2].gpuVA=0;
 resources[2].flags=A5MaliResourceRead;resources[2].uniformBytes=8;m.draw.fragmentBuffers[2].bytes=8;
 p.flags|=A5MaliProfileFragmentPosition;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_attribute_buffer_packed*)(descriptor+0xca0),ATTRIBUTE_BUFFER,pos);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,position);
 assert(pos.special==MALI_ATTRIBUTE_SPECIAL_FRAG_COORD&&!pos.pointer&&!pos.stride&&position.shader.varying_count==3);
 p.flags&=~A5MaliProfileFragmentPosition;
 pass.fragment.firstTag=8;fs[0]=8;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,tagged);
 assert(tagged.shader.shader==m.draw.descriptorGPUVA+0x8008);
 pass.fragment.firstTag=5;fs[0]=5;
 resources[6].flags=A5MaliResourceRead;resources[6].metalIndex=2;
 p.immutableSamplers=NULL;p.immutableSamplerCount=0;
 /* Fetch is a tilebuffer dependency, not a sampled alias of the target. */
 resources[7]=(A5MaliCompiledResource){2,4,0,7,0,1,0,0,0,0};p.resourceCount=8;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));
 p.flags|=A5MaliProfileFramebufferFetch;
 assert(A5MaliDynamicRuntimeProfileSupported(&p));
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,fetch);
 pan_unpack((struct mali_job_header_packed*)(descriptor+0x1800),JOB_HEADER,preload);
 pan_unpack((struct mali_job_header_packed*)(descriptor+0x100),JOB_HEADER,tiler);
 assert(fetch.multisample_misc.load_destination);
 assert(fetch.blend_equation.rgb.b==MALI_BLEND_OPERAND_B_SRC);
 assert(preload.index==2&&tiler.dependency_2==2);
 resources[7].bindingIndex=6;assert(!A5MaliDynamicRuntimeProfileSupported(&p));
 resources[7].bindingIndex=7;resources[7].metalIndex=1;
 assert(!A5MaliDynamicRuntimeProfileSupported(&p));resources[7].metalIndex=0;
 p.flags&=~A5MaliProfileFramebufferFetch;p.resourceCount=7;
 m.fragmentTextures[7].gpuVA=m.colorAttachments[0].gpuVA;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 m.fragmentTextures[7].gpuVA=0x24000000;
 m.fragmentTextures[7].bytes=2047;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 m.fragmentTextures[7].bytes=2048;
 /* Real six-level surface payload, parent-view addresses, LOD and a shader
  * capability gate independent from sampler metadata acceptance. */
 A5RuntimeImage oldImage=m.fragmentTextures[3];A5RuntimeSampler oldSampler=m.fragmentSamplers[0];
 m.fragmentTextures[3]=(A5RuntimeImage){0x23001000,4096,32,32,128,80};
 A5RuntimeMipChain *chain=&m.fragmentMips[3];chain->levelCount=6;
 unsigned w=32,h=32,offset=0;
 for(unsigned level=0;level<6;level++){
  unsigned row=(w*4+15)&~15u;offset=(offset+63)&~63u;
  chain->levels[level]=(A5RuntimeImage){0x23001000+offset,row*h,w,h,row,80};
  offset+=row*h;w=w>1?w/2:1;h=h>1?h/2:1;
 }
 m.fragmentSamplers[0].mipFilter=A5RuntimeSamplerMipLinear;
 m.fragmentSamplers[0].maxAnisotropy=8;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 p.flags|=A5MaliProfileShaderAnisotropy;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_texture_packed*)(descriptor+0x4200),TEXTURE,mips);
 pan_unpack((struct mali_sampler_packed*)(descriptor+0x4140),SAMPLER,filtered);
 assert(mips.width==32&&mips.height==32&&mips.levels==6);
 assert(filtered.mipmap_mode==MALI_MIPMAP_MODE_TRILINEAR&&filtered.maximum_lod==5);
 for(unsigned level=0;level<6;level++){
  pan_unpack((struct mali_surface_with_stride_packed*)(descriptor+0x4220+16*level),SURFACE_WITH_STRIDE,span);
  assert(span.pointer==chain->levels[level].gpuVA&&span.row_stride==chain->levels[level].rowBytes);
 }
 uint32_t n=0,anisotropy=0;memcpy(&n,descriptor+0x1400+352,4);memcpy(&anisotropy,descriptor+0x1400+364,4);
 assert(n==6&&anisotropy==8);
 chain->levels[5].gpuVA=chain->levels[0].gpuVA;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))!=A5RuntimeOK&&zeroed());
 memset(chain,0,sizeof(*chain));m.fragmentTextures[3]=oldImage;m.fragmentSamplers[0]=oldSampler;
 /* Large authenticated dynamic fragments must use the dedicated 16KiB
  * code range, leaving polygon/tiler state and heap outside shader bytes. */
 static uint8_t largeFragment[8992];memset(largeFragment,0x65,sizeof(largeFragment));
 const uint8_t *oldCode=pass.fragment.bytes;unsigned oldBytes=pass.fragment.byteCount;
 pass.fragment.bytes=largeFragment;pass.fragment.byteCount=sizeof(largeFragment);
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeOK);
 pan_unpack((struct mali_renderer_state_packed*)(descriptor+0x540),RENDERER_STATE,largeRSD);
 assert(largeRSD.shader.shader==m.draw.descriptorGPUVA+0xc005);
 assert(!memcmp(descriptor+0xc000,largeFragment,sizeof(largeFragment)));
 assert(descriptor[0x10000]!=0x65);
 pass.fragment.bytes=oldCode;pass.fragment.byteCount=oldBytes;
 p.flags&=~A5MaliProfileShaderAnisotropy;
 m.fragmentSamplers[2].normalizedCoordinates=0;
 assert(A5MaliEncodeRuntimeMiscPass(&m,descriptor,sizeof(descriptor))==A5RuntimeUnsupported&&zeroed());
 puts("PASS dynamic multi-texture descriptors, independent samplers, half4 format, sparse slots and rejection/bounds (no GPU execution)");
 return 0;
}
