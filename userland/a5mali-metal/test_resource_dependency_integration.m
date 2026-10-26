/* SPDX-License-Identifier: MIT
 * Production clear command buffers, real IOSurface aliases and no-copy host
 * storage. Only the kernel query/submission/fence transport is mocked. These
 * tests establish ordering/lifetime contracts, not physical GPU pixel results.
 */
#import "A5MaliRestrictedDevice.h"
#import "A5MaliMetalTexture.h"
#import "A5MaliMetalDeviceResources.h"
#import "A5MaliNative.h"
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
@interface A5MaliMetalBuffer (SchedulingIntegrationSPI)
- (BOOL)commitAndWaitUntilSubmitted;
@end
@interface A5MaliSurface (DependencyIntegrationTest)
- (A5MaliResource)resource;
@end
typedef struct {A5MaliHeader header;uint32_t port,usage;uint64_t reserved;} Import;
typedef struct {A5MaliHeader header;uint64_t token;uint32_t width,height,row,format;} Imported;
typedef struct {A5MaliHeader header;uint64_t token;} DependencyHandleRequest;
typedef struct {A5MaliHeader header;uint64_t token;uint32_t bytes,flags;} Mapped;
typedef struct {
 IOSurfaceRef surfaces[16];uint32_t usage[16];unsigned imports;
 _Atomic unsigned queries,submits,releases;
 uint64_t orderedTokens[8];BOOL gateFirst,badFence;
 dispatch_semaphore_t submitEntered,allowFence;
} State;
static void waitFor(dispatch_semaphore_t semaphore)
{assert(!dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));}
static void blocked(dispatch_semaphore_t semaphore)
{assert(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,75*NSEC_PER_MSEC)));}
static void mustThrow(void(^body)(void))
{BOOL threw=NO;@try{body();}@catch(NSException*exception){(void)exception;threw=YES;}assert(threw);}
static unsigned slot(State*s,uint64_t token)
{assert(token>=UINT64_C(0x100000001));unsigned i=(unsigned)(token-UINT64_C(0x100000001));assert(i<s->imports&&s->surfaces[i]);return i;}
static kern_return_t transport(void*context,uint32_t selector,const void*input,size_t bytes,void*output,size_t*outBytes)
{
 State*s=context;
 if(selector==A5MaliImport){
  const Import*q=input;assert(bytes==sizeof(*q)&&s->imports<16);
  IOSurfaceRef surface=IOSurfaceLookupFromMachPort(q->port);assert(surface);
  unsigned i=s->imports++;s->surfaces[i]=surface;s->usage[i]=q->usage;
  Imported r={{1,sizeof(r),0,0},UINT64_C(0x100000001)+i,(uint32_t)IOSurfaceGetWidth(surface),
   (uint32_t)IOSurfaceGetHeight(surface),(uint32_t)IOSurfaceGetBytesPerRow(surface),IOSurfaceGetPixelFormat(surface)};
  assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);return KERN_SUCCESS;
 }
 if(selector==A5MaliMap){const DependencyHandleRequest*q=input;unsigned i=slot(s,q->token);
  Mapped r={{1,sizeof(r),0,0},q->token,(uint32_t)IOSurfaceGetAllocSize(s->surfaces[i]),s->usage[i]};
  assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);return KERN_SUCCESS;}
 if(selector==A5MaliUnmap)return KERN_SUCCESS;
 if(selector==A5MaliRelease){const DependencyHandleRequest*q=input;unsigned i=slot(s,q->token);
  CFRelease(s->surfaces[i]);s->surfaces[i]=NULL;atomic_fetch_add(&s->releases,1);return KERN_SUCCESS;}
 if(selector==A5NativeQuerySelector){
  const A5NativeQueryRequest*q=input;assert(bytes==sizeof(*q));unsigned i=slot(s,q->surfaces[0]);
  assert(!q->surfaces[1]&&!q->surfaces[2]&&!q->surfaces[3]);
  A5NativeQueryResult r={.header={1,sizeof(r),0,0},.jobVA=A5NativeJobVA,.jobBytes=A5NativeJobBytes,.flags=17};
  IOSurfaceRef surface=s->surfaces[i];r.surfaces[0]=(A5NativeSpan){q->surfaces[0],0x10000000,
   IOSurfaceGetAllocSize(surface),(uint32_t)IOSurfaceGetWidth(surface),(uint32_t)IOSurfaceGetHeight(surface),
   (uint32_t)IOSurfaceGetBytesPerRow(surface),IOSurfaceGetPixelFormat(surface),s->usage[i]};
  assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);
  atomic_fetch_add(&s->queries,1);return KERN_SUCCESS;
 }
 assert(selector==A5NativeSubmitSelector);const A5NativeSubmitRequest*q=input;
 assert(bytes==sizeof(*q)+A5NativeJobBytes&&q->profileID==0&&q->mappingEpoch==17);
 assert(q->vertexOffset==UINT32_MAX&&q->tilerOffset==UINT32_MAX&&!q->fragmentOffset);
 assert(!q->readSurfaces&&q->writeSurfaces==1);unsigned ordinal=atomic_fetch_add(&s->submits,1);assert(ordinal<8);
 s->orderedTokens[ordinal]=q->surfaces[0];
 if(!ordinal&&s->gateFirst){dispatch_semaphore_signal(s->submitEntered);waitFor(s->allowFence);}
 A5NativeSubmitResult r={.header={1,sizeof(r),0,0},.fragmentFence=100+ordinal};
 if(s->badFence)r.fragmentFence=0;
 assert(*outBytes==sizeof(r));memcpy(output,&r,sizeof(r));*outBytes=sizeof(r);return KERN_SUCCESS;
}
static A5MaliRestrictedDevice *device(State*s)
{return [[A5MaliRestrictedDevice alloc]initWithTransport:transport context:s commandCapabilities:63 operationCapabilities:127|(1u<<16)|(1u<<17)];}
static MTLTextureDescriptor *descriptor(void)
{
 MTLTextureDescriptor*d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;return d;
}
static A5MaliMetalBuffer *clear(A5MaliMetalQueue*q,A5MaliMetalTexture*t)
{
 A5MaliMetalBuffer*b=q.commandBuffer;MTLRenderPassDescriptor*p=[MTLRenderPassDescriptor renderPassDescriptor];
 p.colorAttachments[0].texture=(id)t;p.colorAttachments[0].loadAction=MTLLoadActionClear;
 p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(.5,.25,.125,1);
 A5MaliMetalRenderEncoder*e=[b renderCommandEncoderWithDescriptor:p];assert(e);[e endEncoding];return b;
}
static void orderingAndAliases(void)
{
 static State state;state.gateFirst=YES;state.submitEntered=dispatch_semaphore_create(0);state.allowFence=dispatch_semaphore_create(0);
 @autoreleasepool {
  A5MaliRestrictedDevice*d=device(&state);A5MaliMetalTexture*t=[d newTextureWithDescriptor:descriptor()];assert(t);
  IOSurfaceRef surface=t.privateSurface.iosurface;assert(surface);
  A5MaliMetalTexture*alias=[d newTextureWithDescriptor:descriptor() iosurface:surface plane:0];assert(alias&&[t doesAliasResource:alias]);
  A5MaliMetalTexture*view=(id)[alias newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];assert(view&&[view doesAliasResource:t]);
  size_t allocation=IOSurfaceGetAllocSize(surface);void*base=IOSurfaceGetBaseAddress(surface);
  assert(allocation>=4096&&!((uintptr_t)base&4095));
  A5MaliPrivateBuffer*hostAlias=[d newBufferWithBytesNoCopy:base length:allocation options:MTLResourceStorageModeShared deallocator:nil];
  A5MaliPrivateBuffer*independent=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  assert(hostAlias&&independent&&[hostAlias doesAliasResource:t]&&![independent doesAliasResource:t]);
  dispatch_queue_t firstTarget=dispatch_queue_create("a5.test.storage.first",DISPATCH_QUEUE_SERIAL);
  dispatch_queue_t secondTarget=dispatch_queue_create("a5.test.storage.second",DISPATCH_QUEUE_SERIAL);
  A5MaliMetalQueue*first=[d newCommandQueue],*second=[d newCommandQueue];
  [first setSubmissionQueue:firstTarget];[second setSubmissionQueue:secondTarget];dispatch_suspend(firstTarget);
  A5MaliMetalBuffer*a=clear(first,t),*b=clear(second,alias);
  dispatch_semaphore_t scheduled=dispatch_semaphore_create(0),completed=dispatch_semaphore_create(0);
  [a addScheduledHandler:^(id<MTLCommandBuffer> cb){assert(cb.status>=MTLCommandBufferStatusScheduled);dispatch_semaphore_signal(scheduled);}];
  [a addScheduledHandler:^(id<MTLCommandBuffer> cb){[cb waitUntilCompleted];}];
  [a addCompletedHandler:^(id<MTLCommandBuffer> cb){assert(cb.status==MTLCommandBufferStatusCompleted);dispatch_semaphore_signal(completed);}];
  /* Merely encoded work must not make resource completion wait forever. */
  assert(t.isComplete&&hostAlias.isComplete);[hostAlias waitUntilComplete];
  uint64_t firstToken=t.privateSurface.resource.token,secondToken=alias.privateSurface.resource.token;
  [a commit];[b commit];assert(!view.isComplete&&!hostAlias.isComplete&&independent.isComplete);
  dispatch_semaphore_t entered=dispatch_semaphore_create(0),finished=dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
   dispatch_semaphore_signal(entered);[hostAlias waitUntilComplete];dispatch_semaphore_signal(finished);
  }});
  waitFor(entered);blocked(finished);
  dispatch_semaphore_t readEntered=dispatch_semaphore_create(0),readFinished=dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
   uint8_t pixel[4]={0};dispatch_semaphore_signal(readEntered);
   [view getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
   assert([hostAlias readBytes:pixel offset:0 length:4]==KERN_SUCCESS);dispatch_semaphore_signal(readFinished);
  }});
  waitFor(readEntered);blocked(readFinished);
  /* The second queue is runnable but must not overtake the suspended first. */
  assert(!atomic_load(&state.queries)&&!atomic_load(&state.submits));
  __weak A5MaliMetalTexture*retained=t;t=nil;assert(retained);
  dispatch_resume(firstTarget);waitFor(state.submitEntered);blocked(finished);blocked(readFinished);
  blocked(scheduled); /* an unfenced IOMFB consumer must not see producer-ready */
  blocked(completed); /* scheduling is not fake terminal completion */
  assert(!view.isComplete&&!hostAlias.isComplete&&atomic_load(&state.submits)==1);
  dispatch_semaphore_signal(state.allowFence);[a waitUntilCompleted];[b waitUntilCompleted];waitFor(scheduled);waitFor(completed);waitFor(finished);waitFor(readFinished);
  assert([a commitAndWaitUntilSubmitted]&&a.status==MTLCommandBufferStatusCompleted);
  assert(a.status==MTLCommandBufferStatusCompleted&&b.status==MTLCommandBufferStatusCompleted);
  assert(atomic_load(&state.submits)==2&&state.orderedTokens[0]==firstToken&&state.orderedTokens[1]==secondToken);
  assert(view.isComplete&&hostAlias.isComplete&&independent.isComplete);[view waitUntilComplete];
  uint8_t pixel[4]={0};[alias getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
 }
}
static void failedFenceQuarantine(void)
{
 /* The poisoned context intentionally retains its storage until process exit;
  * keep the transport context alive just as long. */
 static State state;state.badFence=YES;
 @autoreleasepool {
  A5MaliRestrictedDevice*d=device(&state);A5MaliMetalTexture*t=[d newTextureWithDescriptor:descriptor()];assert(t);
  A5MaliMetalTexture*alias=[d newTextureWithDescriptor:descriptor() iosurface:t.privateSurface.iosurface plane:0];assert(alias);
  A5MaliMetalBuffer*b=clear([d newCommandQueue],t);[b commit];[b waitUntilCompleted];
  assert(b.status==MTLCommandBufferStatusError&&atomic_load(&state.submits)==1);
  assert(!t.isComplete&&!alias.isComplete);mustThrow(^{[alias waitUntilComplete];});
  A5MaliMetalBuffer*again=clear([d newCommandQueue],alias);[again commit];[again waitUntilCompleted];
  assert(again.status==MTLCommandBufferStatusError&&atomic_load(&state.submits)==1);
  assert(!alias.isComplete);
 }
}
int main(void)
{
 orderingAndAliases();failedFenceQuarantine();
 puts("production CB storage dependencies: IOSurface/view/no-copy aliases, cross-queue order, CPU wait and failed-fence quarantine passed (mock transport)");return 0;
}
