/* SPDX-License-Identifier: MIT
 * Buffer-backed Texture3 for the actual profile603 native path. The IOKit
 * transport is mocked; this checks upload, VA binding, fences and cleanup,
 * not GPU pixels or stock iOS execution.
 */
#import "A5MaliRestrictedDevice.h"
#import "A5MaliMetalDeviceResources.h"
#import "A5MaliMetalTexture.h"
#import "A5MaliNative.h"
#import "A5MaliCompiledRegistry.h"
#ifndef A5_TEST_DYNAMIC_SHADER
#define A5_TEST_DYNAMIC_SHADER 0
#endif
#ifndef A5_TEST_NATIVE_ARENA
#define A5_TEST_NATIVE_ARENA 0
#endif
#ifndef A5_TEST_TEXTURED_PROFILE
#define A5_TEST_TEXTURED_PROFILE 603
#endif
#if A5_TEST_TEXTURED_PROFILE == 603
#define A5_TEST_FRAGMENT_BYTES 880
#elif A5_TEST_TEXTURED_PROFILE == 604
#define A5_TEST_FRAGMENT_BYTES 1120
#elif A5_TEST_TEXTURED_PROFILE == 605
#define A5_TEST_FRAGMENT_BYTES 896
#elif A5_TEST_TEXTURED_PROFILE == 606
#define A5_TEST_FRAGMENT_BYTES 896
#else
#error "expected a real textured603/604/605/606 profile"
#endif
#define MALI_RGBA8_TEST_FORMAT 187u
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#if A5_TEST_DYNAMIC_SHADER
#include <unistd.h>
#import "A5MaliDynamicShaderCache.h"
#include "../a5xelte-air-translation/families/runtime_misc_encode.h"
@interface A5MaliMetalFunction (DynamicStageTransportTest)
- (instancetype)initWithLibrary:(A5MaliMetalLibrary *)library dynamicShader:(A5MaliDynamicShaderCacheEntry *)entry;
@end
uid_t A5MaliDynamicShaderCacheTestUID(void){return geteuid();}
@interface A5MaliReadSurfCandidate (DynamicTransportTest)
- (const A5MaliCompiledProfile *)profile;
@end
#endif

@interface A5MaliMetalBuffer (BufferTexture603FenceTest)
- (A5MaliCommandBuffer *)privateBuffer;
@end
typedef struct {float position[4],uv[2],unused[2];uint16_t color[4];uint8_t pad[8];} Vertex;
_Static_assert(sizeof(Vertex)==48,"actual stock packing0");
typedef enum {Good,FailBulk,FailQuery,FailSubmit,FailMissingClamp,FailShortClamp} Fault;
typedef struct {
    Fault fault;
    BOOL blend;
    unsigned sourceFormat;
    unsigned creates,bulkCalls,queries,submits,releases,deallocations,batches;
    size_t allocated;
    size_t length,uploaded;
    uint8_t *host,*expected,*actual;
    uint64_t handle;
    Vertex vertices[6];
    float matrix[16],transform[4],lod[2];
#if A5_TEST_TEXTURED_PROFILE == 606
    uint8_t clamp[128];
#endif
    const A5MaliCompiledProfile *profile;
} State;
typedef struct {A5MaliHeader header;uint32_t bytes,usage;} Create;
typedef struct {A5MaliHeader header;uint64_t handle;uint32_t bytes,usage;} Created;
typedef struct {A5MaliHeader header;uint64_t handle;} Release;
static uint32_t u32(const uint8_t*p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const uint8_t*p){uint64_t n;memcpy(&n,p,8);return n;}
static BOOL contains(const uint8_t*p,size_t n,const void*v,size_t bytes)
{for(size_t i=0;i+bytes<=n;++i)if(!memcmp(p+i,v,bytes))return YES;return NO;}
static kern_return_t transport(void*context,uint32_t selector,const void*input,size_t bytes,void*output,size_t*outBytes)
{
    State*s=context;
    if(selector==A5MaliUnmap||selector==A5MaliRelease)return KERN_SUCCESS;
    if(selector==8){
        const Create*q=input;assert(bytes==sizeof(*q)&&!s->creates&&q->bytes==(A5_TEST_NATIVE_ARENA?0x40000:s->length)&&q->usage==3);
        s->allocated=q->bytes;
        if(A5_TEST_NATIVE_ARENA){free(s->actual);s->actual=calloc(1,s->allocated);}
        Created r={{1,sizeof(r),0,0},UINT64_C(0x100000101),q->bytes,q->usage};
        assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);
        s->handle=r.handle;++s->creates;return KERN_SUCCESS;
    }
    if(selector==A5NativeBulkWriteSelector){
        const A5NativeBulkWriteRequest*q=input;
        assert(s->creates==1&&q->handle==s->handle&&bytes==sizeof(*q)+q->length);
        assert(q->offset==s->uploaded&&q->length<=A5NativeBulkWriteMax&&q->length<=(A5_TEST_NATIVE_ARENA?s->allocated:s->length)-s->uploaded);
        if(s->fault==FailBulk&&s->bulkCalls==1){++s->bulkCalls;return kIOReturnIOError;}
        memcpy(s->actual+q->offset,(const uint8_t*)input+sizeof(*q),q->length);
        s->uploaded+=q->length;++s->bulkCalls;
        /* A later CPU write cannot affect chunks already captured at COMMIT. */
        if(!A5_TEST_NATIVE_ARENA&&s->bulkCalls==1)s->host[s->length-1]^=0x5a;
        assert(!output&&(!outBytes||!*outBytes));return KERN_SUCCESS;
    }
    if(selector==9){
        const Release*q=input;assert(bytes==sizeof(*q)&&q->handle==s->handle);
        assert(s->releases==0);++s->releases;return KERN_SUCCESS;
    }
    if(selector==A5NativeQuerySelector){
        const A5NativeQueryRequest*q=input;
        assert(bytes==sizeof(*q)&&q->surfaces[0]==UINT64_C(0x100000001));
        assert(!q->surfaces[1]&&!q->surfaces[2]&&!q->surfaces[3]);
        assert(q->buffers[0]==s->handle);
        for(unsigned i=1;i<A5NativeSlots;++i)assert(!q->buffers[i]);
        if(!A5_TEST_NATIVE_ARENA)assert(s->uploaded==s->length&&!memcmp(s->actual,s->expected,s->length));
        ++s->queries;if(s->fault==FailQuery)return kIOReturnBadArgument;
        A5NativeQueryResult r={.header={1,sizeof(r),0,0},.jobVA=A5NativeJobVA,
            .jobBytes=A5NativeJobBytes,.flags=107};
        r.surfaces[0]=(A5NativeSpan){q->surfaces[0],0x10000000,4096,32,32,128,0x42475241,3};
        r.buffers[0]=(A5NativeSpan){q->buffers[0],0x13000000,(uint32_t)(A5_TEST_NATIVE_ARENA?s->allocated:s->length),0,0,0,0,A5MaliRead|A5MaliWrite};
        assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);return KERN_SUCCESS;
    }
    if(selector==A5NativeBatchSelector){
        const A5NativeBatchRequest*h=input;assert(A5_TEST_NATIVE_ARENA&&h->count==8);++s->batches;
        A5NativeBatchResult result={.header={1,sizeof(result),0,0},.count=h->count};
        for(unsigned i=0;i<h->count;i++){
            const void*item=(const uint8_t*)input+sizeof(*h)+i*(sizeof(A5NativeSubmitRequest)+A5NativeJobBytes);
            size_t size=sizeof(result.items[i]);
            assert(!transport(context,A5NativeSubmitSelector,item,sizeof(A5NativeSubmitRequest)+A5NativeJobBytes,&result.items[i],&size));
            ++result.completedCount;
        }
        memcpy(output,&result,sizeof(result));*outBytes=sizeof(result);return KERN_SUCCESS;
    }
    assert(selector==A5NativeSubmitSelector);
    const A5NativeSubmitRequest*q=input;
    assert(bytes==sizeof(*q)+A5NativeJobBytes&&q->profileID==(A5_TEST_DYNAMIC_SHADER?A5MaliDynamicProfileID:A5_TEST_TEXTURED_PROFILE)&&q->mappingEpoch==107);
    assert(q->readSurfaces==1&&q->writeSurfaces==1&&q->readBuffers==1);
    assert(q->surfaces[0]==UINT64_C(0x100000001)&&!q->surfaces[1]&&q->buffers[0]==s->handle);
    size_t arenaOffset=A5_TEST_NATIVE_ARENA?s->submits*s->length:0;
    assert(s->uploaded>=arenaOffset+s->length&&!memcmp(s->actual+arenaOffset,s->expected,s->length));
    const uint8_t*j=(const uint8_t*)input+sizeof(*q);
    const A5MaliCompiledPass*p=s->profile->passes;
    assert(!memcmp(j+0x6000,p->vertex.bytes,p->vertex.byteCount));
    assert(!memcmp(j+0x8000,p->fragment.bytes,p->fragment.byteCount));
    assert(contains(j+0x20000,0x10000,s->vertices,sizeof(s->vertices)));
    assert(contains(j+0x20000,0x10000,s->matrix,sizeof(s->matrix)));
    assert(contains(j+0x20000,0x10000,s->transform,sizeof(s->transform)));
    assert(contains(j+0x20000,0x10000,s->lod,A5_TEST_DYNAMIC_SHADER?4:sizeof(s->lod)));
#if A5_TEST_DYNAMIC_SHADER
    assert(p->fragment.byteCount>0&&p->vertex.byteCount==2192);
    assert((u32(j+(s->profile->flags&A5MaliProfileShaderAnisotropy?0x4008:0x608))&0x3fffff)==((163u<<12)|0x124u));
#endif
#if A5_TEST_TEXTURED_PROFILE == 606
    assert(p->vertex.byteCount==2192&&p->fragment.byteCount==A5_TEST_FRAGMENT_BYTES);
    /* CPU Shared bindings are captured from their public offset at COMMIT.
     * The private arena holds the 128-byte prefix with offset folded to zero. */
    uint64_t descriptor=u64(j+0x740+3*8);
    uint64_t pointer=(descriptor>>12)<<4;
    assert((descriptor&0xfff)==7&&pointer>=A5NativeJobVA+0x20000);
    assert(pointer-A5NativeJobVA<=A5NativeJobBytes-sizeof(s->clamp));
    assert(!memcmp(j+(size_t)(pointer-A5NativeJobVA),s->clamp,sizeof(s->clamp)));
    assert(u32(j+0x1400+64)==0&&u32(j+0x1400+68)==0);
    assert(u32(j+0x1400+72)==0x2222);
    /* Released v4 R8_UNORM(163) with channel swizzle 000R: stored R is
     * alpha for A8; ordinary R8's implicit alpha one would render opaque. */
    assert((u32(j+(s->profile->flags&A5MaliProfileShaderAnisotropy?0x4008:0x608))&0x3fffff)==((163u<<12)|0x124u));
#endif
    if(s->sourceFormat==70||s->sourceFormat==80)
        assert((u32(j+0x608)&0x3fffff)==((MALI_RGBA8_TEST_FORMAT<<12)|(s->sourceFormat==70?0x688u:0x60au)));
    unsigned textureOffset=s->profile->flags&A5MaliProfileShaderAnisotropy?0x4000:0x600;
    assert(u32(j+textureOffset)==((16u-1)<<16|31u));
    assert(u64(j+textureOffset+32)==UINT64_C(0x13000080)+arenaOffset&&u32(j+textureOffset+40)==256&&u32(j+textureOffset+44)==4096);
    assert(u64(j+(textureOffset==0x600?0x680:0x4100))==A5NativeJobVA+textureOffset);
#if A5_TEST_DYNAMIC_SHADER
    if(s->profile->flags&A5MaliProfileShaderAnisotropy)assert(u32(j+0x1400+364)==8);
#endif
    assert(A5NativeCheckJobChain(j,A5NativeJobBytes,A5NativeJobVA,0,0x100,0x200,NO)==1);
    ++s->submits;if(s->fault==FailSubmit)return kIOReturnTimeout;
    A5NativeSubmitResult r={.header={1,sizeof(r),0,0},.tilerFence=1902,.fragmentFence=1903};
    if(A5_TEST_NATIVE_ARENA){r.tilerFence=1900+2*s->submits;r.fragmentFence=r.tilerFence+1;}
    assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);return KERN_SUCCESS;
}
static MTLFunctionConstantValues *constants(BOOL vertex)
{
    size_t count=0;const A5MaliCompiledFunctionConstant *c=vertex?
        A5MaliCompiledVertexConstantsForProfile(A5_TEST_TEXTURED_PROFILE,&count):A5MaliCompiledConstantsForProfile(A5_TEST_TEXTURED_PROFILE,&count);
    assert(c&&count==(vertex?4u:58u));MTLFunctionConstantValues *result=[MTLFunctionConstantValues new];
    for(size_t i=0;i<count;++i)[result setConstantValue:c[i].raw type:c[i].dataType
        withName:[NSString stringWithUTF8String:c[i].name]];
#if A5_TEST_DYNAMIC_SHADER
    if(!vertex){uint8_t image=17;[result setConstantValue:&image type:MTLDataTypeUChar withName:@"fc_image_function0"];}
#endif
    return result;
}
static A5MaliReadSurfCandidate *pipeline(A5MaliRestrictedDevice *device,State *s)
{
    const char *path=getenv("A5_MALI_STOCK_QUARTZCORE_METALLIB");assert(path);
    NSError *error=nil;A5MaliMetalLibrary *library=[device newLibraryWithURL:
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] error:&error];assert(library&&!error);
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=(id)[library newFunctionWithName:@"fixed_vert_lph_spc" constantValues:constants(YES) error:&error];
    d.fragmentFunction=(id)[library newFunctionWithName:@"fixed_frag_lph_cph" constantValues:constants(NO) error:&error];
#if A5_TEST_DYNAMIC_SHADER
    const char *vertexRequest=getenv("A5_TEST_DYNAMIC_VERTEX_REQUEST");
    if(vertexRequest){
        NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:vertexRequest]];
        NSMutableDictionary *request=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
        NSString *requestID=request[@"request_id"];
        [request removeObjectForKey:@"owner_uid"];[request removeObjectForKey:@"request_id"];
        A5MaliDynamicShaderCacheEntry *entry=A5MaliLoadDynamicShaderStage(requestID,request,&error);
        assert(entry&&!error&&entry.stage==A5MaliStageVertex);
        d.vertexFunction=(id)[[A5MaliMetalFunction alloc]initWithLibrary:library dynamicShader:entry];
        assert([(A5MaliMetalFunction *)d.vertexFunction dynamicShader]==entry);
    }
#endif
    assert(d.vertexFunction&&d.fragmentFunction&&!error);d.vertexDescriptor=[MTLVertexDescriptor vertexDescriptor];
    assert(s->profile->attributeCount==4&&s->profile->layoutCount==1);
    for(unsigned i=0;i<4;++i){const A5MaliCompiledVertexAttribute *a=s->profile->attributes+i;
        d.vertexDescriptor.attributes[a->index].format=a->format;
        d.vertexDescriptor.attributes[a->index].offset=a->offset;
        d.vertexDescriptor.attributes[a->index].bufferIndex=a->bufferIndex;
    }
    const A5MaliCompiledVertexLayout *l=s->profile->layouts;
    d.vertexDescriptor.layouts[l->index].stride=l->stride;
    d.vertexDescriptor.layouts[l->index].stepFunction=l->stepFunction;
    d.vertexDescriptor.layouts[l->index].stepRate=l->stepRate;
    for(unsigned i=0;i<8;++i){const A5MaliCompiledAttachmentState *a=&s->profile->attachmentContracts[s->blend?1:0].attachments[i];
        MTLRenderPipelineColorAttachmentDescriptor *actual=d.colorAttachments[i];
        actual.pixelFormat=s->profile->colorFormats[i];actual.writeMask=a->writeMask;actual.blendingEnabled=a->blendEnabled;
        actual.rgbBlendOperation=a->rgbOperation;actual.alphaBlendOperation=a->alphaOperation;
        actual.sourceRGBBlendFactor=a->sourceRGB;actual.destinationRGBBlendFactor=a->destinationRGB;
        actual.sourceAlphaBlendFactor=a->sourceAlpha;actual.destinationAlphaBlendFactor=a->destinationAlpha;
    }
    if(s->blend){
        assert(s->profile->flags&A5MaliProfileSourceOverBlend);
        /* RGB and alpha equations are independent API state, not a pair whitelist. */
        d.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorZero;
        assert([device newRenderPipelineStateWithDescriptor:d error:&error]&&!error);
        d.colorAttachments[0].rgbBlendOperation=MTLBlendOperationMin;
        assert(![device newRenderPipelineStateWithDescriptor:d error:&error]&&error);
        d.colorAttachments[0].rgbBlendOperation=MTLBlendOperationAdd;
        d.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        error=nil;
    }
#if A5_TEST_DYNAMIC_SHADER
    MTLLinkedFunctions *linked=[MTLLinkedFunctions new];linked.functions=@[d.vertexFunction];
    d.vertexLinkedFunctions=linked;
    assert(![device newRenderPipelineStateWithDescriptor:d error:&error]&&error);
    d.vertexLinkedFunctions=nil;error=nil;
    d.vertexDescriptor.attributes[0].offset=1; /* Unaligned; aligned repacking is supported. */
    assert(![device newRenderPipelineStateWithDescriptor:d error:&error]&&error);
    d.vertexDescriptor.attributes[0].offset=0;error=nil;
#endif
    A5MaliReadSurfCandidate *result=[device newRenderPipelineStateWithDescriptor:d error:&error];assert(result&&!error);
#if A5_TEST_DYNAMIC_SHADER
    s->profile=[result profile];assert(s->profile&&s->profile->profileID==A5MaliDynamicProfileID);
    assert(A5MaliDynamicRuntimeProfileSupported(s->profile));
    A5MaliCompiledProfile changed=*s->profile;A5MaliCompiledResource resources[16];
    memcpy(resources,changed.resources,changed.resourceCount*sizeof(*resources));changed.resources=resources;
    resources[0].flags|=A5MaliResourceWrite;assert(!A5MaliDynamicRuntimeProfileSupported(&changed));
    resources[0].flags=A5MaliResourceRead;resources[0].nativeIndex=8;
    assert(!A5MaliDynamicRuntimeProfileSupported(&changed));
    resources[0]=s->profile->resources[0];changed.flags|=A5MaliProfileNotExecutable;
    assert(!A5MaliDynamicRuntimeProfileSupported(&changed));
#endif
    return result;
}
static A5MaliMetalBuffer *encode(A5MaliRestrictedDevice*d,id pipelineState,
    A5MaliMetalTexture*target,A5MaliMetalTexture*source,State*s)
{
    A5MaliMetalBuffer*b=[[d newCommandQueue]commandBuffer];assert(b);
    MTLRenderPassDescriptor*pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=(id)target;
    pass.colorAttachments[0].loadAction=MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    A5MaliMetalRenderEncoder*r=[b renderCommandEncoderWithDescriptor:pass];assert(r);
    [r setRenderPipelineState:pipelineState];[r setViewport:(MTLViewport){0,0,32,32,0,1}];
    A5MaliPrivateBuffer*vb=[d newBufferWithLength:sizeof(s->vertices)+32 options:MTLResourceStorageModeShared];
    A5MaliPrivateBuffer*matrix=[d newBufferWithLength:80 options:MTLResourceStorageModeShared];
    A5MaliPrivateBuffer*uv=[d newBufferWithLength:32 options:MTLResourceStorageModeShared];
    A5MaliPrivateBuffer*lod=[d newBufferWithLength:24 options:MTLResourceStorageModeShared];
    assert(vb.contents&&matrix.contents&&uv.contents&&lod.contents);
    [r setVertexBuffer:vb offset:16 atIndex:1];[r setVertexBuffer:matrix offset:16 atIndex:2];
    [r setVertexBuffer:uv offset:16 atIndex:3];[r setFragmentBuffer:lod offset:16 atIndex:2];
#if A5_TEST_TEXTURED_PROFILE == 606
    NSUInteger clampBytes=s->fault==FailShortClamp?127:128;
    A5MaliPrivateBuffer*clamp=[d newBufferWithLength:clampBytes+16 options:MTLResourceStorageModeShared];
    assert(clamp.contents);memset(clamp.contents,0xd3,clampBytes+16);
    if(s->fault!=FailMissingClamp)[r setFragmentBuffer:clamp offset:16 atIndex:1];
#endif
    MTLSamplerDescriptor*sd=[MTLSamplerDescriptor new];
    sd.minFilter=MTLSamplerMinMagFilterNearest;sd.magFilter=sd.minFilter;
    sd.mipFilter=MTLSamplerMipFilterLinear;sd.lodMinClamp=.25f;sd.lodMaxClamp=4;
#if A5_TEST_DYNAMIC_SHADER
    sd.maxAnisotropy=8;
#endif
    A5MaliSamplerState*sampler=[d newSamplerStateWithDescriptor:sd];assert(sampler);
    [r setFragmentSamplerState:sampler atIndex:0];[r setFragmentTexture:source atIndex:3];
    for(unsigned i=0;i<(A5_TEST_NATIVE_ARENA?8u:1u);i++)
        [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [r setFragmentTexture:nil atIndex:3];[r endEncoding];
    memcpy((uint8_t*)vb.contents+16,s->vertices,sizeof(s->vertices));
    memcpy((uint8_t*)matrix.contents+16,s->matrix,sizeof(s->matrix));
    memcpy((uint8_t*)uv.contents+16,s->transform,sizeof(s->transform));
    memcpy((uint8_t*)lod.contents+16,s->lod,sizeof(s->lod));
#if A5_TEST_TEXTURED_PROFILE == 606
    /* This write follows both draw encoding and endEncoding. The uniform
     * snapshot must retain these bytes rather than the earlier 0xd3 values. */
    memcpy((uint8_t*)clamp.contents+16,s->clamp,clampBytes);
#endif
    assert(!b.privateBuffer.completedFence.fragmentFence);return b;
}
static void runCaseFormat(Fault fault,BOOL useSPI,BOOL blend,MTLPixelFormat sourceFormat)
{
    State s={.fault=fault,.blend=blend,.length=0x101000};
    if(A5_TEST_NATIVE_ARENA)s.length=0x2000;
    s.sourceFormat=sourceFormat;
    s.profile=A5MaliCompiledProfileForID(A5_TEST_TEXTURED_PROFILE);assert(s.profile);
    s.expected=malloc(s.length);s.actual=calloc(1,s.length);
    assert(s.expected&&s.actual);
    for(size_t i=0;i<s.length;++i)s.expected[i]=(uint8_t)(i*29u+7u);
    for(unsigned i=0;i<6;++i){s.vertices[i].position[0]=i+.25f;
        s.vertices[i].position[1]=i*.75f;s.vertices[i].position[3]=1;
        s.vertices[i].uv[0]=i*3+.5f;s.vertices[i].uv[1]=i+.125f;
        s.vertices[i].color[0]=0x3800;s.vertices[i].color[1]=0x3400;
        s.vertices[i].color[2]=0x3a00;s.vertices[i].color[3]=0x3c00;}
    s.matrix[0]=1.25f;s.matrix[5]=1.75f;s.matrix[10]=2;s.matrix[15]=1;
    s.transform[0]=.03125f;s.transform[1]=.0625f;
    s.lod[0]=.375f;s.lod[1]=.625f;
#if A5_TEST_TEXTURED_PROFILE == 606
    for(unsigned i=0;i<sizeof(s.clamp);++i)s.clamp[i]=(uint8_t)(0x57+i*13);
    const float limits[4]={.125f,.25f,.75f,.875f};memcpy(s.clamp+112,limits,sizeof(limits));
#endif
    @autoreleasepool{
        A5MaliRestrictedDevice*d=[[A5MaliRestrictedDevice alloc]initWithTransport:transport
            context:&s commandCapabilities:(A5_TEST_NATIVE_ARENA?127:63) operationCapabilities:0xfffff];
        id p=pipeline(d,&s);assert(p);
        A5MaliMetalTexture*target=[d hostTestTextureWithResource:
            (A5MaliResource){0x100000001,32,32,128,3}];
        assert(!posix_memalign((void **)&s.host,4096,s.length));
        memcpy(s.host,s.expected,s.length);
        State *state=&s;
        A5MaliPrivateBuffer*buffer=[d newBufferWithBytesNoCopy:s.host length:s.length
            options:MTLResourceStorageModeShared deallocator:^(void*ptr,NSUInteger len){
                assert(ptr==state->host&&len==state->length);++state->deallocations;free(ptr);
            }];
        assert(buffer&&buffer.contents==s.host&&buffer.privateKernelHandle==0);
        MTLTextureDescriptor*desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            sourceFormat width:32 height:16 mipmapped:NO];
        desc.usage=MTLTextureUsageShaderRead;desc.storageMode=MTLStorageModeShared;
        A5MaliMetalTexture*source=(id)(useSPI?
            [buffer newLinearTextureWithDescriptor:desc offset:128 bytesPerRow:256 bytesPerImage:4160]:
            [buffer newTextureWithDescriptor:desc offset:128 bytesPerRow:256]);
        assert(source&&source.buffer==buffer&&!source.privateSurface&&source.bufferOffset==128);
        assert(source.bufferBytesPerRow==256&&source.bufferBytesPerImage==(useSPI?4160u:4096u));
        A5MaliTextureLevelLayout l={0};assert([source getLevelLayout:&l level:0]);
        assert(l.byteOffset==128&&l.byteLength==4096&&l.rowBytes==256);
        /* Reject an out-of-bounds physical view instead of substituting an
         * independent IOSurface for the same public buffer. */
        assert(![buffer newTextureWithDescriptor:desc offset:s.length-128 bytesPerRow:256]);
        A5MaliMetalBuffer*b=encode(d,p,target,source,&s);
        buffer=nil;source=nil;
        assert(!s.creates&&!s.bulkCalls&&!s.queries&&!s.submits);
        /* Shared and no-copy bytes change after encoding but before COMMIT. */
#if A5_TEST_TEXTURED_PROFILE == 606
        if(fault==FailMissingClamp||fault==FailShortClamp){
            /* Rejected draws retain no image: releasing the public source
             * already calls its deallocator, so there is no late CPU write. */
            assert(s.deallocations==1);
        }else
#endif
        {
        assert(!s.deallocations);
        s.host[128]=0xa5;s.expected[128]=0xa5;
        }
        [b commit];[b waitUntilCompleted];
#if A5_TEST_TEXTURED_PROFILE == 606
        if(fault==FailMissingClamp||fault==FailShortClamp){
            assert(b.status==MTLCommandBufferStatusError&&b.error);
            assert(!s.creates&&!s.bulkCalls&&!s.queries&&!s.submits&&!s.releases);
            assert(!b.privateBuffer.completedFence.tilerFence&&!b.privateBuffer.completedFence.fragmentFence);
            b=nil;
        }else{
#endif
        assert(s.creates==1&&s.releases==1);
        if(A5_TEST_NATIVE_ARENA){
            assert(fault==Good&&s.bulkCalls==1&&s.queries==1&&s.submits==8&&s.batches==1);
            assert(b.status==MTLCommandBufferStatusCompleted&&!b.error);
            assert(b.privateBuffer.completedFence.fragmentFence==1917);
        }else{
        if(fault==FailBulk){assert(s.bulkCalls==2&&!s.queries&&!s.submits);}
        else if(fault==FailQuery){assert(s.bulkCalls==2&&s.queries==1&&!s.submits);}
        else {assert(s.bulkCalls==2&&s.queries==1&&s.submits==1);}
        if(fault==Good){assert(b.status==MTLCommandBufferStatusCompleted&&!b.error);
            assert(b.privateBuffer.completedFence.tilerFence==1902&&b.privateBuffer.completedFence.fragmentFence==1903);}
        else {assert(b.status==MTLCommandBufferStatusError&&b.error);
            assert(!b.privateBuffer.completedFence.tilerFence&&!b.privateBuffer.completedFence.fragmentFence);}
        }
        b=nil;
#if A5_TEST_TEXTURED_PROFILE == 606
        }
#endif
    }
    /* An uncertain Submit18 keeps the no-copy storage quarantined.
     * Only jobs that never launch or reach a terminal fence may free it. */
    assert(s.deallocations==(fault==FailSubmit?0u:1u));
    free(s.expected);free(s.actual);
}
static void runCase(Fault fault,BOOL useSPI,BOOL blend)
{
#if A5_TEST_TEXTURED_PROFILE == 606 || A5_TEST_DYNAMIC_SHADER
    runCaseFormat(fault,useSPI,blend,MTLPixelFormatA8Unorm);
#else
    runCaseFormat(fault,useSPI,blend,MTLPixelFormatBGRA8Unorm);
#endif
}
int main(void)
{
#if A5_TEST_TEXTURED_PROFILE != 606 && !A5_TEST_DYNAMIC_SHADER
    runCaseFormat(Good,NO,NO,MTLPixelFormatRGBA8Unorm);
    runCaseFormat(Good,YES,YES,MTLPixelFormatRGBA8Unorm);
#endif
    runCase(Good,NO,NO);runCase(Good,YES,NO);
    runCase(Good,NO,YES);runCase(Good,YES,YES);
#if A5_TEST_TEXTURED_PROFILE == 604 || A5_TEST_TEXTURED_PROFILE == 605
    runCaseFormat(Good,NO,NO,MTLPixelFormatRG8Unorm);
    runCaseFormat(Good,YES,YES,MTLPixelFormatR8Unorm);
#endif
#if A5_TEST_TEXTURED_PROFILE == 606
    runCase(FailMissingClamp,NO,NO);runCase(FailShortClamp,NO,NO);
#endif
    if(!A5_TEST_NATIVE_ARENA){runCase(FailBulk,NO,YES);runCase(FailQuery,NO,YES);runCase(FailSubmit,NO,YES);}
    printf("buffer-backed native%d: copy/source-over pipelines, real no-copy Shared alias, commit snapshot, full bulk upload, bufferVA+offset, fences and cleanup PASS (mock transport; no GPU pixels)\n",A5_TEST_TEXTURED_PROFILE);
    return 0;
}
