/* SPDX-License-Identifier: MIT */
#import "A5MaliMetalDeviceResources.h"
#import "A5MaliMetalTexture.h"
#import "A5MaliNative.h"
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <math.h>
#include <unistd.h>

enum { CreateBuffer = 8, ReleaseBuffer = 9, WriteBuffer = 14,
       ReadBuffer = 15, TransferMax = 256 };
typedef struct { A5MaliHeader h; uint32_t bytes, usage; } CreateRequest;
typedef struct { A5MaliHeader h; uint64_t handle; uint32_t bytes, usage; } CreateReply;
typedef struct { A5MaliHeader h; uint64_t handle; } ReleaseRequest;
typedef struct {
    A5MaliHeader h; uint64_t handle; uint32_t offset, length;
    uint8_t bytes[TransferMax];
} TransferRequest;
typedef struct {
    A5MaliHeader h; uint32_t length, reserved; uint8_t bytes[TransferMax];
} ReadReply;
_Static_assert(sizeof(CreateRequest) == 24 && sizeof(CreateReply) == 32,
    "kernel0155 create ABI");
_Static_assert(sizeof(TransferRequest) == 288 && sizeof(ReadReply) == 280,
    "kernel0155 transfer ABI");

@interface A5MaliRestrictedDevice (ResourcePrivateDevice)
- (A5MaliDevice *)privateDevice;
@end
@interface A5MaliDevice (ResourcePrivateClient)
- (A5MaliClient *)client;
- (NSLock *)lock;
@end
@interface A5MaliSurface (ResourceAliasIdentity)
- (A5MaliResource)resource;
@end

@interface A5MaliResourceAccounting : NSObject
@property (nonatomic) NSUInteger bytes;
@property (nonatomic) NSUInteger sharedBytes;
@end
@implementation A5MaliResourceAccounting
@end
static char accountingKey;
static A5MaliResourceAccounting *accounting(A5MaliRestrictedDevice *device)
{
    @synchronized (device) {
        A5MaliResourceAccounting *result = objc_getAssociatedObject(device, &accountingKey);
        if (!result) {
            result = [A5MaliResourceAccounting new];
            objc_setAssociatedObject(device, &accountingKey, result,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return result;
    }
}
NSUInteger A5MaliAllocatedPrivateBufferBytes(A5MaliRestrictedDevice *device)
{
    A5MaliResourceAccounting *state = accounting(device);
    @synchronized (state) { return state.bytes; }
}
NSUInteger A5MaliAllocatedSharedReadBufferBytes(A5MaliRestrictedDevice *device)
{
    A5MaliResourceAccounting *state = accounting(device);
    @synchronized (state) { return state.sharedBytes; }
}

static A5MaliHeader wireHeader(NSUInteger size)
{ return (A5MaliHeader){A5MaliProtocolVersion, (uint32_t)size, 0, 0}; }
static BOOL validHeader(A5MaliHeader h, NSUInteger expected, NSUInteger actual)
{ return expected == actual && h.version == A5MaliProtocolVersion &&
    h.size == expected && !h.reserved0 && !h.reserved1; }
static char dependenciesKey;
A5MaliResourceDependencies *A5MaliDependenciesForDevice(A5MaliRestrictedDevice *device)
{
    @synchronized(device){
        A5MaliResourceDependencies *registry=objc_getAssociatedObject(device,&dependenciesKey);
        if(!registry){registry=[A5MaliResourceDependencies new];
            objc_setAssociatedObject(device,&dependenciesKey,registry,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        return registry;
    }
}
static NSUInteger bufferStorageSpans(A5MaliPrivateBuffer *buffer,uint64_t offset,
    uint64_t length,A5MaliStorageSpan *spans)
{
    spans[0]=A5MaliMakeStorageSpan(A5MaliStorageAllocation,(uint64_t)(uintptr_t)(__bridge void *)buffer,offset,length);
    void *base=[buffer a5StorageContents];
    if(!base)return 1;
    uint64_t address=(uint64_t)(uintptr_t)base;
    spans[1]=offset>UINT64_MAX-address?
        A5MaliMakeWholeStorageSpan(A5MaliStorageHostRange,0):
        A5MaliMakeStorageSpan(A5MaliStorageHostRange,0,address+offset,length);
    return 2;
}
A5MaliStorageIdentity *A5MaliStorageForResource(id value)
{
    A5MaliStorageSpan spans[4];NSUInteger count=0;id owner=value;
    if([value isKindOfClass:A5MaliPrivateBuffer.class]){
        A5MaliPrivateBuffer *buffer=value;
        count=bufferStorageSpans(buffer,0,buffer.length,spans);
    }else if([value isKindOfClass:A5MaliMetalTexture.class]){
        A5MaliMetalTexture *texture=value;A5MaliTextureLevelLayout first={0},last={0};
        A5MaliSurface *backing=texture.privateSurface;
        if(backing)owner=@[value,backing];
        BOOL valid=texture.mipmapLevelCount&&[texture getLevelLayout:&first level:0]&&
            [texture getLevelLayout:&last level:texture.mipmapLevelCount-1]&&
            last.byteOffset>=first.byteOffset;
        if(!valid){spans[count++]=A5MaliMakeWholeStorageSpan(A5MaliStorageUnknown,0);}
        else{
            uint64_t bytes=(uint64_t)last.byteOffset+last.byteLength-first.byteOffset;
            A5MaliMetalTexture *root=texture;
            for(unsigned depth=0;root.parentTexture&&depth<64;depth++)root=root.parentTexture;
            if(root.parentTexture)spans[count++]=A5MaliMakeWholeStorageSpan(A5MaliStorageUnknown,0);
            else spans[count++]=A5MaliMakeStorageSpan(A5MaliStorageAllocation,
                (uint64_t)(uintptr_t)(__bridge void *)root,first.byteOffset,bytes);
            A5MaliPrivateBuffer *buffer=texture.buffer?:root.buffer;
            if(buffer)count+=bufferStorageSpans(buffer,first.byteOffset,bytes,spans+count);
            else{
                IOSurfaceRef surface=texture.privateSurface.iosurface;
                if(surface){
                    spans[count++]=A5MaliMakeStorageSpan(A5MaliStorageIOSurface,
                        IOSurfaceGetID(surface),first.byteOffset,bytes);
                    void *base=IOSurfaceGetBaseAddress(surface);
                    if(base){uint64_t address=(uint64_t)(uintptr_t)base;
                        spans[count++]=first.byteOffset>UINT64_MAX-address?
                            A5MaliMakeWholeStorageSpan(A5MaliStorageHostRange,0):
                            A5MaliMakeStorageSpan(A5MaliStorageHostRange,0,address+first.byteOffset,bytes);}
                }
            }
        }
    }else return nil;
    return [[A5MaliStorageIdentity alloc]initWithOwner:owner spans:spans count:count];
}
BOOL A5MaliResourcesAlias(id a,id b)
{
    A5MaliStorageIdentity *left=A5MaliStorageForResource(a),*right=A5MaliStorageForResource(b);
    return left&&right&&A5MaliResourceStoragesAlias(left,right);
}
static A5MaliRestrictedDevice *resourceDevice(id resource)
{
    return ([resource isKindOfClass:A5MaliPrivateBuffer.class]||
        [resource isKindOfClass:A5MaliMetalTexture.class])?[resource device]:nil;
}
BOOL A5MaliResourceIsComplete(id resource)
{
    A5MaliStorageIdentity *storage=A5MaliStorageForResource(resource);
    A5MaliRestrictedDevice *device=resourceDevice(resource);
    return storage&&device&&[A5MaliDependenciesForDevice(device)isCompleteForStorage:storage];
}
void A5MaliWaitForResource(id resource,A5MaliResourceAccess access)
{
    A5MaliStorageIdentity *storage=A5MaliStorageForResource(resource);
    A5MaliRestrictedDevice *device=resourceDevice(resource);
    if(!storage||!device)[NSException raise:NSInvalidArgumentException format:@"unknown resource storage"];
    [A5MaliDependenciesForDevice(device)waitForStorage:storage access:access];
}
static BOOL hasSelector(A5MaliClient *client, uint32_t selector)
{ return client && client->call &&
    (client->supportedOperations & (1U << (selector - 1))) != 0; }
static void logBufferPurge(MTLStorageMode storage,BOOL external,MTLPurgeableState requested,
    MTLPurgeableState prior,MTLPurgeableState actual,kern_return_t status)
{
    static atomic_uint count;unsigned n=atomic_load_explicit(&count,memory_order_relaxed);
    do{if(n>=64)return;}while(!atomic_compare_exchange_weak_explicit(&count,&n,n+1,memory_order_relaxed,memory_order_relaxed));
    fprintf(stderr,"A5XELTE Metal buffer purge: storage=%lu external=%u requested=%lu prior=%lu actual=%lu result=%x\n",
        (unsigned long)storage,external,(unsigned long)requested,(unsigned long)prior,(unsigned long)actual,status);
}
static kern_return_t call(A5MaliDevice *device, uint32_t selector,
    const void *input, size_t inputSize, void *output, size_t *outputSize)
{
    [[device lock] lock];
    A5MaliClient *client = [device client];
    size_t noOutput = 0;
    size_t capacity=outputSize?*outputSize:0;
    kern_return_t result = hasSelector(client, selector) ?
        client->call(client->context, selector, input, inputSize, output,
            outputSize ?: &noOutput) : kIOReturnUnsupported;
    if(selector==CreateBuffer){
        for(unsigned retry=0;result==kIOReturnNoResources&&retry<4;retry++){
            if(A5MaliEvictIdleNativeUpload(client)!=KERN_SUCCESS)break;
            if(outputSize)*outputSize=capacity;
            result=client->call(client->context,selector,input,inputSize,output,outputSize?:&noOutput);
        }
    }
    [[device lock] unlock];
    return result;
}

MTLSizeAndAlign A5MaliPrivateBufferSizeAndAlign(NSUInteger length,
    MTLResourceOptions options)
{
    /* This size query describes pinned private BOs. Shared buffers instead
     * snapshot their actual CPU bytes at submission; no mmap is fabricated. */
    if (!length || length > A5MaliMaxPrivateBufferLength ||
        options != MTLResourceStorageModePrivate)
        return (MTLSizeAndAlign){0, 0};
    return (MTLSizeAndAlign){(length + 4095) & ~(NSUInteger)4095, 4096};
}
MTLSizeAndAlign A5MaliBGRA8TextureSizeAndAlign(MTLTextureDescriptor *d)
{
    A5MaliTextureAllocationLayout layout;
    if(!A5MaliBuildTextureAllocationLayout(d,&layout,NULL)||d.storageMode==MTLStorageModeMemoryless)
        return (MTLSizeAndAlign){0,0};
    return (MTLSizeAndAlign){(layout.totalBytes+4095)&~(NSUInteger)4095,4096};
}

@interface A5MaliPrivateBuffer () {
    A5MaliRestrictedDevice *_device;
    A5MaliDevice *_privateDevice;
    A5MaliResourceAccounting *_accounting;
    NSUInteger _length, _allocatedSize;
    atomic_uint_fast64_t _handle;
    NSLock *_transferLock;
    atomic_bool _readyForRead;
    atomic_uint _purgeState;
}
- (nullable instancetype)initWithDevice:(A5MaliRestrictedDevice *)device
    length:(NSUInteger)length options:(MTLResourceOptions)options;
@end

@implementation A5MaliPrivateBuffer
- (instancetype)initWithDevice:(A5MaliRestrictedDevice *)device
    length:(NSUInteger)length options:(MTLResourceOptions)options
{
    MTLSizeAndAlign size = A5MaliPrivateBufferSizeAndAlign(length, options);
    if (!size.size || !(self = [super init])) return nil;
    _device = device;
    _privateDevice = [device privateDevice];
    if (!_privateDevice) return nil;
    A5MaliClient *client = [_privateDevice client];
    if (!hasSelector(client, CreateBuffer) || !hasSelector(client, ReleaseBuffer) ||
        !hasSelector(client, WriteBuffer) || !hasSelector(client, ReadBuffer))
        return nil;
    CreateRequest request = {wireHeader(sizeof(request)),
        (uint32_t)size.size, A5MaliRead | A5MaliWrite};
    CreateReply reply = {0};
    size_t actual = sizeof(reply);
    kern_return_t status = call(_privateDevice, CreateBuffer, &request,
        sizeof(request), &reply, &actual);
    if (status != KERN_SUCCESS) return nil;
    uint32_t low = (uint32_t)reply.handle;
    if (!validHeader(reply.h, sizeof(reply), actual) || !(reply.handle >> 32) ||
        low < 0x101 || low >= 0x101 + A5MaliPrivateBufferSlots ||
        reply.bytes != size.size || reply.usage != request.usage) {
        if (reply.handle) {
            ReleaseRequest release = {wireHeader(sizeof(release)), reply.handle};
            call(_privateDevice, ReleaseBuffer, &release, sizeof(release), NULL, NULL);
        }
        return nil;
    }
    _handle = reply.handle;
    _length = length;
    _allocatedSize = size.size;
    _transferLock = [NSLock new];
    _readyForRead = YES;
    _purgeState=MTLPurgeableStateNonVolatile;
    _accounting = accounting(device);
    @synchronized (_accounting) { _accounting.bytes += size.size; }
    return self;
}
- (void)dealloc
{
    if (_handle) {
        ReleaseRequest request = {wireHeader(sizeof(request)), _handle};
        kern_return_t kr = call(_privateDevice, ReleaseBuffer, &request,
            sizeof(request), NULL, NULL);
        /* If the kernel retained a failed release, keep it counted. */
        if (kr == KERN_SUCCESS)
            @synchronized (_accounting) { _accounting.bytes -= _allocatedSize; }
    }
}
- (A5MaliRestrictedDevice *)device { return _device; }
- (NSUInteger)length { return _length; }
- (NSUInteger)allocatedSize { return _handle?_allocatedSize:0; }
- (MTLStorageMode)storageMode { return MTLStorageModePrivate; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeDefault; }
- (MTLResourceOptions)resourceOptions { return MTLResourceStorageModePrivate; }
- (uint64_t)privateKernelHandle { return _handle; }
- (BOOL)readyForRead
{
    /* A command owns the device lock while checking this flag. Taking the
     * transfer lock here would invert upload's transfer -> device lock order. */
    return _handle && atomic_load_explicit(&_readyForRead,memory_order_acquire) &&
        atomic_load_explicit(&_purgeState,memory_order_acquire)==MTLPurgeableStateNonVolatile;
}
- (id<MTLHeap>)heap{return nil;}
- (NSUInteger)heapOffset{return 0;}
- (BOOL)isAliasable{return NO;}
- (void)makeAliasable
{[NSException raise:NSInvalidArgumentException format:@"makeAliasable requires a heap-backed resource"];}
- (MTLGPUAddress)gpuAddress{return 0;}
- (uint64_t)allocationID{return 0;}
- (uint64_t)protectionOptions{return 0;}
- (uint64_t)unfilteredResourceOptions{return self.resourceOptions;}
- (int)responsibleProcess
{ @synchronized(self){NSNumber *hint=objc_getAssociatedObject(self,@selector(responsibleProcess));return hint?hint.intValue:getpid();} }
- (void)setResponsibleProcess:(int)process
{
    if(process<0)[NSException raise:NSInvalidArgumentException format:@"negative responsible process hint"];
    @synchronized(self){objc_setAssociatedObject(self,@selector(responsibleProcess),@(process),OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
}
- (kern_return_t)setOwnerWithIdentity:(uint32_t)identity
{(void)identity;return kIOReturnUnsupported;}
- (BOOL)isPurgeable{return [self setPurgeableState:MTLPurgeableStateKeepCurrent]!=MTLPurgeableStateNonVolatile;}
- (BOOL)isComplete{return A5MaliResourceIsComplete(self);}
- (void)waitUntilComplete
{A5MaliWaitForResource(self,A5MaliResourceAccessRead|A5MaliResourceAccessWrite);}
- (BOOL)doesAliasResource:(id)resource{return A5MaliResourcesAlias(self,resource);}
- (BOOL)doesAliasAnyResources:(id const __unsafe_unretained *)resources count:(NSUInteger)count
{
    if((count&&!resources)||count>4096)[NSException raise:NSInvalidArgumentException format:@"invalid resource alias array"];
    for(NSUInteger i=0;i<count;++i)if(A5MaliResourcesAlias(self,resources[i]))return YES;return NO;
}
- (BOOL)doesAliasAllResources:(id const __unsafe_unretained *)resources count:(NSUInteger)count
{
    if((count&&!resources)||count>4096)[NSException raise:NSInvalidArgumentException format:@"invalid resource alias array"];
    for(NSUInteger i=0;i<count;++i)if(!A5MaliResourcesAlias(self,resources[i]))return NO;return YES;
}
- (void)didModifyRange:(NSRange)range
{(void)range;[NSException raise:NSInvalidArgumentException format:@"didModifyRange requires unsupported Managed storage"];}
- (NSArray<NSDictionary *> *)debugMarkers
{ @synchronized(self){return [objc_getAssociatedObject(self,@selector(debugMarkers)) copy]?:@[];} }
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range
{
    if(![marker isKindOfClass:NSString.class]||range.location>self.length||range.length>self.length-range.location)
        [NSException raise:NSInvalidArgumentException format:@"buffer debug marker range invalid"];
    @synchronized(self){
        NSMutableArray *markers=[self.debugMarkers mutableCopy];
        [markers addObject:@{@"marker":[marker copy],@"range":[NSValue valueWithRange:range]}];
        objc_setAssociatedObject(self,@selector(debugMarkers),markers,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
- (void)removeAllDebugMarkers
{ @synchronized(self){objc_setAssociatedObject(self,@selector(debugMarkers),nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);} }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state
{
    if(state<MTLPurgeableStateKeepCurrent||state>MTLPurgeableStateEmpty)
        [NSException raise:NSInvalidArgumentException format:@"invalid buffer purgeable state"];
    if(state!=MTLPurgeableStateKeepCurrent)A5MaliWaitForResource(self,A5MaliResourceAccessWrite);
    [_transferLock lock];
    MTLPurgeableState prior=atomic_load_explicit(&_purgeState,memory_order_acquire);
    kern_return_t status=KERN_SUCCESS;
    if(state==MTLPurgeableStateEmpty&&_handle){
        ReleaseRequest q={wireHeader(sizeof(q)),_handle};
        status=call(_privateDevice,ReleaseBuffer,&q,sizeof(q),NULL,NULL);
        if(!status){_handle=0;atomic_store_explicit(&_readyForRead,NO,memory_order_release);
            @synchronized(_accounting){_accounting.bytes-=_allocatedSize;}}
    }else if(state==MTLPurgeableStateNonVolatile&&prior==MTLPurgeableStateEmpty){
        CreateRequest q={wireHeader(sizeof(q)),(uint32_t)_allocatedSize,A5MaliRead|A5MaliWrite};
        CreateReply r={0};size_t size=sizeof(r);
        status=call(_privateDevice,CreateBuffer,&q,sizeof(q),&r,&size);
        uint32_t low=(uint32_t)r.handle;
        if(!status&&(!validHeader(r.h,sizeof(r),size)||!(r.handle>>32)||low<0x101||low>=0x105||r.bytes!=q.bytes||r.usage!=q.usage)){
            if(r.handle){ReleaseRequest release={wireHeader(sizeof(release)),r.handle};
                call(_privateDevice,ReleaseBuffer,&release,sizeof(release),NULL,NULL);}
            status=kIOReturnBadArgument;
        }
        if(!status){_handle=r.handle;atomic_store_explicit(&_readyForRead,YES,memory_order_release);
            @synchronized(_accounting){_accounting.bytes+=_allocatedSize;}}
    }
    if(!status&&state!=MTLPurgeableStateKeepCurrent)
        atomic_store_explicit(&_purgeState,(unsigned)(prior==MTLPurgeableStateEmpty&&state==MTLPurgeableStateVolatile?
            MTLPurgeableStateEmpty:state),memory_order_release);
    [_transferLock unlock];
    logBufferPurge(MTLStorageModePrivate,NO,state,prior,atomic_load_explicit(&_purgeState,memory_order_acquire),status);
    if(status)[NSException raise:NSInternalInconsistencyException format:@"kernel buffer purge transition failed: %x",status];
    return prior;
}
- (void *)contents { return NULL; }
- (void *)a5StorageContents { return NULL; }
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
    offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow
{ return (id)[A5MaliMetalTexture newBufferTextureWithBuffer:self descriptor:descriptor
    offset:offset bytesPerRow:bytesPerRow bytesPerImage:0]; }
- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
    offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
{ return (id)[A5MaliMetalTexture newBufferTextureWithBuffer:self descriptor:descriptor
    offset:offset bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage]; }
- (kern_return_t)transferBytes:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length write:(BOOL)write
{
    if (!bytes || !length || offset > _length || length > _length - offset)
        return kIOReturnBadArgument;
    [_transferLock lock];
    if(atomic_load_explicit(&_purgeState,memory_order_acquire)!=MTLPurgeableStateNonVolatile){
        [_transferLock unlock];return kIOReturnNotReady;}
    BOOL wasReady=atomic_load_explicit(&_readyForRead,memory_order_acquire);
    if(write)atomic_store_explicit(&_readyForRead,NO,memory_order_release);
    kern_return_t result = KERN_SUCCESS;
    for (NSUInteger done = 0; done < length; ) {
        NSUInteger count = MIN((NSUInteger)TransferMax, length - done);
        TransferRequest request = {0};
        request.h = wireHeader(sizeof(request));
        request.handle = _handle;
        request.offset = (uint32_t)(offset + done);
        request.length = (uint32_t)count;
        if (write) memcpy(request.bytes, (uint8_t *)bytes + done, count);
        ReadReply reply = {0};
        size_t actual = sizeof(reply);
        result = call(_privateDevice, write ? WriteBuffer : ReadBuffer,
            &request, sizeof(request), write ? NULL : &reply,
            write ? NULL : &actual);
        if (result != KERN_SUCCESS) break;
        if (!write) {
            if (!validHeader(reply.h, sizeof(reply), actual) ||
                reply.reserved || reply.length != count) {
                result = kIOReturnBadArgument;
                break;
            }
            memcpy((uint8_t *)bytes + done, reply.bytes, count);
        }
        done += count;
    }
    if (write) {
        BOOL complete=result==KERN_SUCCESS && (wasReady || (!offset && length==_length));
        atomic_store_explicit(&_readyForRead,complete,memory_order_release);
    }
    [_transferLock unlock];
    return result;
}
- (kern_return_t)uploadBytes:(const void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length
{ A5MaliWaitForResource(self,A5MaliResourceAccessWrite);return [self transferBytes:(void *)bytes offset:offset length:length write:YES]; }
- (kern_return_t)readBytes:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length
{ A5MaliWaitForResource(self,A5MaliResourceAccessRead);return [self transferBytes:bytes offset:offset length:length write:NO]; }
- (kern_return_t)a5TransferBytesWithoutWaiting:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length write:(BOOL)write
{ return [self transferBytes:bytes offset:offset length:length write:write]; }
- (kern_return_t)readBytesForSubmission:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length client:(A5MaliClient *)client
{
    if (!bytes || !length || !self.readyForRead || offset>_length || length>_length-offset ||
        client!=[_privateDevice client] || !hasSelector(client,ReadBuffer))return kIOReturnBadArgument;
    /* The device lock already serializes transport. Taking _transferLock here
     * would invert the public upload's transferLock -> deviceLock ordering. */
    for(NSUInteger done=0;done<length;){
        NSUInteger count=MIN((NSUInteger)TransferMax,length-done);
        TransferRequest request={.h=wireHeader(sizeof(request)),.handle=_handle,
            .offset=(uint32_t)(offset+done),.length=(uint32_t)count};
        ReadReply reply={0};size_t actual=sizeof(reply);
        kern_return_t status=client->call(client->context,ReadBuffer,&request,sizeof(request),&reply,&actual);
        if(status)return status;
        if(!validHeader(reply.h,sizeof(reply),actual)||reply.reserved||reply.length!=count)
            return kIOReturnBadArgument;
        memcpy((uint8_t *)bytes+done,reply.bytes,count);done+=count;
    }
    return KERN_SUCCESS;
}
@end

@interface A5MaliSharedReadBuffer ()
- (nullable instancetype)initSharedWithDevice:(A5MaliRestrictedDevice *)device
    length:(NSUInteger)length;
- (nullable instancetype)initNoCopyWithDevice:(A5MaliRestrictedDevice *)device
    bytes:(void *)bytes length:(NSUInteger)length
    deallocator:(nullable void (^)(void *,NSUInteger))deallocator;
@end
@implementation A5MaliSharedReadBuffer {
    A5MaliRestrictedDevice *_sharedDevice;
    A5MaliResourceAccounting *_sharedAccounting;
    NSLock *_sharedLock;
    void *_sharedContents;
    NSUInteger _sharedLength, _sharedAllocation;
    BOOL _sharedExternal;
    void (^_sharedDeallocator)(void *,NSUInteger);
    atomic_uint _sharedPurgeState;
}
- (instancetype)initSharedWithDevice:(A5MaliRestrictedDevice *)device length:(NSUInteger)length
{
    if (!device || !length || length > A5MaliMaxPrivateBufferLength ||
        !(self = [super init])) return nil;
    NSUInteger allocation = (length + 4095) & ~(NSUInteger)4095;
    A5MaliResourceAccounting *state = accounting(device);
    @synchronized (state) {
        /* Read staging is bounded separately from the four pinned kernel BOs. */
        if (state.sharedBytes > 64 * 1024 * 1024 - allocation) return nil;
        void *pointer = NULL;
        if (posix_memalign(&pointer, 4096, allocation)) return nil;
        memset(pointer, 0, allocation);
        state.sharedBytes += allocation;
        _sharedContents = pointer;
    }
    _sharedDevice = device; _sharedAccounting = state;
    _sharedLength = length; _sharedAllocation = allocation;
    _sharedLock = [NSLock new];
    _sharedPurgeState=MTLPurgeableStateNonVolatile;
    return self;
}
- (instancetype)initNoCopyWithDevice:(A5MaliRestrictedDevice *)device
    bytes:(void *)bytes length:(NSUInteger)length
    deallocator:(void (^)(void *,NSUInteger))deallocator
{
    if(!device||!bytes||!length||length>A5MaliMaxPrivateBufferLength||
        ((uintptr_t)bytes&(A5MaliBufferPageSize-1))||
        (length&(A5MaliBufferPageSize-1))||(uintptr_t)bytes>UINTPTR_MAX-length||
        ![[device privateDevice] supportsNativePrograms]||!(self=[super init]))return nil;
    NSLock *lock=[NSLock new];if(!lock)return nil;
    /* Copy the block before taking ownership/accounting. A failed creation
     * never invokes it or frees caller memory. No caller byte is read here. */
    void (^releaseBytes)(void *,NSUInteger)=[deallocator copy];
    A5MaliResourceAccounting *state=accounting(device);
    @synchronized(state){
        if(state.sharedBytes>64*1024*1024-length)return nil;
        state.sharedBytes+=length;
    }
    _sharedDevice=device;_sharedAccounting=state;_sharedLock=lock;
    _sharedLength=length;_sharedAllocation=length;_sharedExternal=YES;
    _sharedDeallocator=releaseBytes;_sharedContents=bytes;
    _sharedPurgeState=MTLPurgeableStateNonVolatile;
    return self;
}
- (void)dealloc
{
    if (_sharedContents) {
        void *bytes=_sharedContents;
        void (^deallocator)(void *,NSUInteger)=_sharedDeallocator;
        _sharedContents=NULL;_sharedDeallocator=nil;
        @synchronized (_sharedAccounting) { _sharedAccounting.sharedBytes -= _sharedAllocation; }
        /* Never call caller code while holding accounting/transfer locks.
         * The device remains retained through the callback's lifetime. */
        if(_sharedExternal){if(deallocator)deallocator(bytes,_sharedLength);}
        else free(bytes);
    }
}
- (A5MaliRestrictedDevice *)device { return _sharedDevice; }
- (NSUInteger)length { return _sharedLength; }
- (NSUInteger)allocatedSize { [_sharedLock lock];NSUInteger bytes=_sharedAllocation;[_sharedLock unlock];return bytes; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (MTLResourceOptions)resourceOptions { return MTLResourceStorageModeShared; }
- (uint64_t)privateKernelHandle { return 0; }
- (BOOL)readyForRead { return atomic_load_explicit(&_sharedPurgeState,memory_order_acquire)==MTLPurgeableStateNonVolatile; }
- (void *)contents { return [self a5StorageContents]; }
- (void *)a5StorageContents { [_sharedLock lock];void *p=_sharedContents;[_sharedLock unlock];return p; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state
{
    if(state<MTLPurgeableStateKeepCurrent||state>MTLPurgeableStateEmpty)
        [NSException raise:NSInvalidArgumentException format:@"invalid Shared buffer purgeable state"];
    if(state!=MTLPurgeableStateKeepCurrent)A5MaliWaitForResource(self,A5MaliResourceAccessWrite);
    [_sharedLock lock];MTLPurgeableState prior=atomic_load_explicit(&_sharedPurgeState,memory_order_acquire);
    BOOL failed=NO;
    if(state==MTLPurgeableStateEmpty&&prior!=MTLPurgeableStateEmpty&&!_sharedExternal){
        free(_sharedContents);_sharedContents=NULL;
        @synchronized(_sharedAccounting){_sharedAccounting.sharedBytes-=_sharedAllocation;}
        _sharedAllocation=0;
    }else if(state==MTLPurgeableStateNonVolatile&&prior==MTLPurgeableStateEmpty&&!_sharedExternal){
        NSUInteger allocation=(_sharedLength+4095)&~(NSUInteger)4095;void *p=NULL;
        @synchronized(_sharedAccounting){
            if(_sharedAccounting.sharedBytes>64*1024*1024-allocation||posix_memalign(&p,4096,allocation))failed=YES;
            else {_sharedAccounting.sharedBytes+=allocation;memset(p,0,allocation);}
        }
        if(!failed){_sharedContents=p;_sharedAllocation=allocation;}
    }
    /* No-copy pages remain owned by their caller. Empty invalidates their
     * resource contents/readability, but never releases pages or invokes the
     * ownership callback ahead of the last buffer/view/command reference. */
    if(!failed&&state!=MTLPurgeableStateKeepCurrent)
        atomic_store_explicit(&_sharedPurgeState,(unsigned)(prior==MTLPurgeableStateEmpty&&state==MTLPurgeableStateVolatile?
            MTLPurgeableStateEmpty:state),memory_order_release);
    [_sharedLock unlock];
    logBufferPurge(MTLStorageModeShared,_sharedExternal,state,prior,
        atomic_load_explicit(&_sharedPurgeState,memory_order_acquire),failed?kIOReturnNoMemory:KERN_SUCCESS);
    if(failed)[NSException raise:NSMallocException format:@"Shared buffer restoration after purge failed"];
    return prior;
}
- (kern_return_t)sharedTransfer:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length write:(BOOL)write
{
    if (!bytes || !length || offset > _sharedLength || length > _sharedLength - offset)
        return kIOReturnBadArgument;
    [_sharedLock lock];
    if(atomic_load_explicit(&_sharedPurgeState,memory_order_acquire)!=MTLPurgeableStateNonVolatile){
        [_sharedLock unlock];return kIOReturnNotReady;}
    if (write) memcpy((uint8_t *)_sharedContents + offset, bytes, length);
    else memcpy(bytes, (uint8_t *)_sharedContents + offset, length);
    [_sharedLock unlock];
    return KERN_SUCCESS;
}
- (kern_return_t)uploadBytes:(const void *)bytes offset:(NSUInteger)offset length:(NSUInteger)length
{ A5MaliWaitForResource(self,A5MaliResourceAccessWrite);return [self sharedTransfer:(void *)bytes offset:offset length:length write:YES]; }
- (kern_return_t)readBytes:(void *)bytes offset:(NSUInteger)offset length:(NSUInteger)length
{ A5MaliWaitForResource(self,A5MaliResourceAccessRead);return [self sharedTransfer:bytes offset:offset length:length write:NO]; }
- (kern_return_t)a5TransferBytesWithoutWaiting:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length write:(BOOL)write
{ return [self sharedTransfer:bytes offset:offset length:length write:write]; }
- (kern_return_t)readBytesForSubmission:(void *)bytes offset:(NSUInteger)offset
    length:(NSUInteger)length client:(A5MaliClient *)client
{ (void)client;return [self sharedTransfer:bytes offset:offset length:length write:NO]; }
@end

static NSError *bindingError(kern_return_t status, NSString *message)
{
    return [NSError errorWithDomain:@"com.orhunnx.a5xelte.mali" code:status
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
@implementation A5MaliBufferBinding {
    A5MaliRestrictedDevice *_device;
    A5MaliPrivateBuffer *_buffer;
    NSData *_bytes;
    NSUInteger _offset, _length;
}
+ (instancetype)bindingWithBuffer:(A5MaliPrivateBuffer *)buffer offset:(NSUInteger)offset
    length:(NSUInteger)length device:(A5MaliRestrictedDevice *)device error:(NSError **)error
{
    if (error) *error = nil;
    if (![buffer isKindOfClass:[A5MaliPrivateBuffer class]] || buffer.device != device ||
        !length || offset > buffer.length || length > buffer.length - offset ||
        !buffer.readyForRead) {
        if (error) *error = bindingError(kIOReturnBadArgument, @"invalid or unreadable same-device buffer range");
        return nil;
    }
    A5MaliBufferBinding *binding = [self new];
    binding->_device = device; binding->_buffer = buffer;
    binding->_offset = offset; binding->_length = length;
    return binding;
}
+ (instancetype)bindingWithBytes:(const void *)bytes length:(NSUInteger)length
    device:(A5MaliRestrictedDevice *)device error:(NSError **)error
{
    if (error) *error = nil;
    if (!bytes || !device || !length || length > 4096) {
        if (error) *error = bindingError(kIOReturnBadArgument, @"setBytes requires 1..4096 actual bytes");
        return nil;
    }
    A5MaliBufferBinding *binding = [self new];
    binding->_device = device; binding->_length = length;
    binding->_bytes = [NSData dataWithBytes:bytes length:length];
    return binding;
}
- (A5MaliRestrictedDevice *)device { return _device; }
- (A5MaliPrivateBuffer *)buffer { return _buffer; }
- (NSUInteger)offset { return _offset; }
- (NSUInteger)length { return _length; }
- (uint64_t)privateKernelHandle { return _buffer.privateKernelHandle; }
- (BOOL)inlineBytes { return _bytes != nil; }
- (NSData *)captureBytesForSubmission:(NSError **)error
{ return [self capturePrefixBytesForSubmission:_length error:error]; }
- (NSData *)capturePrefixBytesForSubmission:(NSUInteger)length error:(NSError **)error
{
    if (error) *error = nil;
    if (!length || length > _length) {
        if (error) *error = bindingError(kIOReturnBadArgument, @"submission window exceeds bound buffer bytes");
        return nil;
    }
    if (_bytes) return [_bytes subdataWithRange:NSMakeRange(0, length)];
    if (![_buffer isKindOfClass:[A5MaliSharedReadBuffer class]] || !_buffer.readyForRead) {
        if (error) *error = bindingError(kIOReturnUnsupported,
            @"private buffer bindings require the retained kernel handle and range");
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    kern_return_t result = [_buffer readBytesForSubmission:data.mutableBytes offset:_offset
        length:length client:[[_buffer.device privateDevice]client]];
    if (result != KERN_SUCCESS) {
        if (error) *error = bindingError(result, @"shared read binding capture failed");
        return nil;
    }
    return [data copy];
}
@end

@interface A5MaliSamplerState ()
- (instancetype)initWithDevice:(A5MaliRestrictedDevice *)device descriptor:(MTLSamplerDescriptor *)descriptor;
@end
@implementation A5MaliSamplerState {
    A5MaliRestrictedDevice *_device;
    MTLSamplerDescriptor *_descriptor;
}
- (instancetype)initWithDevice:(A5MaliRestrictedDevice *)device descriptor:(MTLSamplerDescriptor *)descriptor
{ if ((self = [super init])) { _device = device; _descriptor = [descriptor copy]; } return self; }
- (A5MaliRestrictedDevice *)device { return _device; }
- (NSString *)label { return _descriptor.label; }
- (MTLSamplerDescriptor *)descriptor { return [_descriptor copy]; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){0}; }
- (MTLPixelFormat)pixelFormat { return MTLPixelFormatInvalid; }
@end
@interface A5MaliDepthStencilState ()
- (instancetype)initWithDevice:(A5MaliRestrictedDevice *)device descriptor:(MTLDepthStencilDescriptor *)descriptor;
@end
@implementation A5MaliDepthStencilState {
    A5MaliRestrictedDevice *_device;
    MTLDepthStencilDescriptor *_descriptor;
}
- (instancetype)initWithDevice:(A5MaliRestrictedDevice *)device descriptor:(MTLDepthStencilDescriptor *)descriptor
{ if ((self = [super init])) { _device = device; _descriptor = [descriptor copy]; } return self; }
- (A5MaliRestrictedDevice *)device { return _device; }
- (NSString *)label { return _descriptor.label; }
- (MTLDepthStencilDescriptor *)descriptor { return [_descriptor copy]; }
- (BOOL)readsDepth {return _descriptor.depthCompareFunction!=MTLCompareFunctionAlways&&_descriptor.depthCompareFunction!=MTLCompareFunctionNever;}
- (BOOL)writesDepth {return _descriptor.depthWriteEnabled;}
- (BOOL)writesStencil
{
    MTLStencilDescriptor *faces[]={_descriptor.frontFaceStencil,_descriptor.backFaceStencil};
    for(unsigned i=0;i<2;++i){MTLStencilDescriptor *s=faces[i];
        if(s&&s.writeMask&&(s.stencilFailureOperation!=MTLStencilOperationKeep||
            s.depthFailureOperation!=MTLStencilOperationKeep||s.depthStencilPassOperation!=MTLStencilOperationKeep))return YES;
    }return NO;
}
- (BOOL)readsStencil
{
    MTLStencilDescriptor *faces[]={_descriptor.frontFaceStencil,_descriptor.backFaceStencil};
    for(unsigned f=0;f<2;++f){MTLStencilDescriptor *s=faces[f];if(!s)continue;
        if(s.readMask&&s.stencilCompareFunction!=MTLCompareFunctionAlways&&s.stencilCompareFunction!=MTLCompareFunctionNever)return YES;
        MTLStencilOperation ops[]={s.stencilFailureOperation,s.depthFailureOperation,s.depthStencilPassOperation};
        for(unsigned i=0;i<3;++i)if(s.writeMask&&ops[i]!=MTLStencilOperationKeep&&
            (s.writeMask!=UINT32_MAX||(ops[i]!=MTLStencilOperationZero&&ops[i]!=MTLStencilOperationReplace)))return YES;
    }
    return NO;
}
@end

static const char *samplerRejectionReason(MTLSamplerDescriptor *d)
{
    if(!d)return "nil-descriptor";
    if(d.minFilter!=MTLSamplerMinMagFilterNearest&&d.minFilter!=MTLSamplerMinMagFilterLinear)return "min-filter";
    if(d.magFilter!=MTLSamplerMinMagFilterNearest&&d.magFilter!=MTLSamplerMinMagFilterLinear)return "mag-filter";
    if(d.mipFilter!=MTLSamplerMipFilterNotMipmapped&&d.mipFilter!=MTLSamplerMipFilterNearest&&
        d.mipFilter!=MTLSamplerMipFilterLinear)return "mip-filter";
    if(d.maxAnisotropy<1||d.maxAnisotropy>16)return "anisotropy";
    if(d.sAddressMode!=MTLSamplerAddressModeClampToEdge||d.tAddressMode!=MTLSamplerAddressModeClampToEdge||
        d.rAddressMode!=MTLSamplerAddressModeClampToEdge)return "address-mode";
    if(!d.normalizedCoordinates)return "unnormalized-coordinates";
    if(d.compareFunction!=MTLCompareFunctionNever)return "compare-function";
    if(d.supportArgumentBuffers)return "argument-buffers";
    if(!isfinite(d.lodMinClamp)||!isfinite(d.lodMaxClamp)||d.lodMinClamp<0||d.lodMaxClamp<d.lodMinClamp)
        return "lod-range";
    return NULL;
}
static void logSamplerRejection(MTLSamplerDescriptor *d,const char *reason)
{
    static atomic_uint count;
    unsigned value=atomic_load_explicit(&count,memory_order_relaxed);
    do {if(value>=64)return;} while(!atomic_compare_exchange_weak_explicit(&count,&value,value+1,
        memory_order_relaxed,memory_order_relaxed));
    fprintf(stderr,"A5XELTE Metal sampler: rejected reason=%s min=%lu mag=%lu mip=%lu anisotropy=%lu address=%lu/%lu/%lu normalized=%u compare=%lu argument_buffers=%u lod_min=%g lod_max=%g\n",
        reason,(unsigned long)d.minFilter,(unsigned long)d.magFilter,(unsigned long)d.mipFilter,
        (unsigned long)d.maxAnisotropy,(unsigned long)d.sAddressMode,(unsigned long)d.tAddressMode,
        (unsigned long)d.rAddressMode,d.normalizedCoordinates,(unsigned long)d.compareFunction,
        d.supportArgumentBuffers,(double)d.lodMinClamp,(double)d.lodMaxClamp);
}

static BOOL noStencilOperation(MTLStencilDescriptor *stencil)
{
    return !stencil ||
        (stencil.stencilCompareFunction == MTLCompareFunctionAlways &&
         stencil.stencilFailureOperation == MTLStencilOperationKeep &&
         stencil.depthFailureOperation == MTLStencilOperationKeep &&
         stencil.depthStencilPassOperation == MTLStencilOperationKeep);
}

static void logBufferRejection(NSUInteger length,MTLResourceOptions options,const char *reason)
{
    static atomic_uint count;
    unsigned value=atomic_load_explicit(&count,memory_order_relaxed);
    do {if(value>=64)return;} while(!atomic_compare_exchange_weak_explicit(&count,&value,value+1,
        memory_order_relaxed,memory_order_relaxed));
    fprintf(stderr,"A5XELTE Metal buffer: rejected reason=%s length=%lu options=%lu\n",
        reason,(unsigned long)length,(unsigned long)options);
}
@implementation A5MaliRestrictedDevice (PrivateBufferResources)
- (A5MaliPrivateBuffer *)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
    A5MaliPrivateBuffer *buffer=options==MTLResourceStorageModeShared?
        [[A5MaliSharedReadBuffer alloc] initSharedWithDevice:self length:length]:
        [[A5MaliPrivateBuffer alloc] initWithDevice:self length:length options:options];
    if(!buffer)logBufferRejection(length,options,!length||length>A5MaliMaxPrivateBufferLength?
        "length":(options!=MTLResourceStorageModeShared&&options!=MTLResourceStorageModePrivate)?
        "options":"allocation-or-kernel-create");
    return buffer;
}
- (A5MaliPrivateBuffer *)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length
    options:(MTLResourceOptions)options
{
    if (!bytes || options != MTLResourceStorageModeShared){
        logBufferRejection(length,options,!bytes?"nil-source":"bytes-require-shared");return nil;
    }
    A5MaliSharedReadBuffer *buffer = [[A5MaliSharedReadBuffer alloc]
        initSharedWithDevice:self length:length];
    BOOL uploaded=[buffer uploadBytes:bytes offset:0 length:length] == KERN_SUCCESS;
    if(!uploaded||!buffer)logBufferRejection(length,options,"shared-allocation-or-upload");
    return uploaded?buffer:nil;
}
- (A5MaliPrivateBuffer *)newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length
    options:(MTLResourceOptions)options deallocator:(void (^)(void *, NSUInteger))deallocator
{
    if(options!=MTLResourceStorageModeShared){
        logBufferRejection(length,options,"no-copy-requires-shared-default-options");return nil;
    }
    A5MaliSharedReadBuffer *buffer=[[A5MaliSharedReadBuffer alloc]initNoCopyWithDevice:self
        bytes:bytes length:length deallocator:deallocator];
    if(!buffer)logBufferRejection(length,options,!bytes?"no-copy-nil-source":
        !length||length>A5MaliMaxPrivateBufferLength?"no-copy-length":
        ((uintptr_t)bytes&(A5MaliBufferPageSize-1))||(length&(A5MaliBufferPageSize-1))?"no-copy-page-alignment":
        (uintptr_t)bytes>UINTPTR_MAX-length?"no-copy-address-span":
        ![[self privateDevice] supportsNativePrograms]?"no-copy-native-queue-unavailable":"no-copy-accounting-or-allocation");
    return buffer;
}
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
    if (options == MTLResourceStorageModeShared && length &&
        length <= A5MaliMaxPrivateBufferLength)
        return (MTLSizeAndAlign){(length + 4095) & ~(NSUInteger)4095, 4096};
    return A5MaliPrivateBufferSizeAndAlign(length, options);
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor
{ return A5MaliBGRA8TextureSizeAndAlign(descriptor); }
- (A5MaliSamplerState *)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
    MTLSamplerDescriptor *snapshot=[d copy];
    const char *reason=samplerRejectionReason(snapshot);
    if(reason){logSamplerRejection(snapshot,reason);return nil;}
    /* Creation retains exact state. Individual native shader profiles still
     * decide which filter/mip/LOD states their compiled specialization admits. */
    return [[A5MaliSamplerState alloc] initWithDevice:self descriptor:snapshot];
}
- (A5MaliDepthStencilState *)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d
{
    if (!d || d.depthCompareFunction != MTLCompareFunctionAlways ||
        d.depthWriteEnabled || !noStencilOperation(d.frontFaceStencil) ||
        !noStencilOperation(d.backFaceStencil))
        return nil;
    return [[A5MaliDepthStencilState alloc] initWithDevice:self descriptor:d];
}
@end
