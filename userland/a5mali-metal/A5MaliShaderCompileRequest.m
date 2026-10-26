/* SPDX-License-Identifier: MIT
 * Bounded automatic forwarding to the native compiler worker. No commands,
 * caller paths, shader substitutes or GPU addresses cross this interface.
 */
#import "A5MaliShaderCompileRequest.h"
#import "A5MaliBlendRequest.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "A5MaliShaderSpool.h"

#ifndef A5_SHADER_REQUEST_HOST_TEST
static const char *const spoolRoot="/private/var/tmp/a5mali-shader-requests";
#else
#ifndef A5_SHADER_REQUEST_TEST_ROOT
#error "Host request tests require an explicit private spool root"
#endif
static const char *const spoolRoot=A5_SHADER_REQUEST_TEST_ROOT;
#endif
static NSString *const sourceSHA=@"11c74cc42ce5137b73d44d427f75764f886656d4ddb374422d56b609ed2762d9";
enum { kMaxRequestBytes=128*1024, kMaxPending=64, kMaxConstants=64 };

@interface MTLFunctionConstantValues (A5MaliRequestConstantSPI)
- (NSArray *)newNamedConstantArray;
- (NSArray *)newIndexedConstantArray;
@end
@interface MTLLinkedFunctions (A5MaliRequestLinkedSPI)
- (NSArray *)privateFunctions;
@end
@protocol A5MaliRequestConstantRecord
- (NSString *)name;
- (NSUInteger)index;
- (MTLDataType)dataType;
- (const void *)data;
@end

static id reject(NSError **error,NSString *reason)
{
    if(error)*error=[NSError errorWithDomain:@"com.orhunnx.a5xelte.shader-request"
        code:EINVAL userInfo:@{NSLocalizedDescriptionKey:reason}];
    return nil;
}
static BOOL identifier(id value)
{
    if(![value isKindOfClass:NSString.class] || ![value length] || [value length]>128)return NO;
    const char *s=[value UTF8String];
    if(!s||strlen(s)!=[value length])return NO;
    for(;*s;++s)if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||
        (*s>='0'&&*s<='9')||*s=='_'))return NO;
    return YES;
}
static NSDictionary *base(NSString *kind)
{
    return @{ @"schema":@1,@"kind":kind,@"source_library":@"quartzcore",
        @"metallib_sha256":sourceSHA,@"gpu_id":@"07201000",@"compiler_abi":@1 };
}
/* Exact copied-constant widths, not vector ABI alignment. The iOS16 stock
 * _MTLConstantDataSize table agrees, including UChar3=3/Float3=12/Long3=24.
 * Matrices/objects/unknown types are not silently read at a guessed width. */
static NSUInteger constantBytes(NSUInteger type)
{
    if(type>=3&&type<=6)return 4*(type-2);
    if(type>=16&&type<=19)return 2*(type-15);
    if(type>=29&&type<=36)return 4*(1+(type-29)%4);
    if(type>=37&&type<=44)return 2*(1+(type-37)%4);
    if(type>=45&&type<=56)return 1+(type-45)%4;
    if(type>=81&&type<=88)return 8*(1+(type-81)%4);
    return 0;
}
static NSArray *captureConstants(MTLFunctionConstantValues *values,BOOL indexed,NSError **error)
{
    if(!values)return @[];
    SEL selector=indexed?@selector(newIndexedConstantArray):@selector(newNamedConstantArray);
    if(![values respondsToSelector:selector])return reject(error,@"typed constant accessor unavailable");
    NSArray *array=indexed?[values newIndexedConstantArray]:[values newNamedConstantArray];
    if(![array isKindOfClass:NSArray.class] || array.count>kMaxConstants)
        return reject(error,@"constant array unavailable or exceeds64 entries");
    Class expected=NSClassFromString(indexed?@"MTLIndexedConstantValue":@"MTLNamedConstantValue");
    NSMutableArray *result=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(id object in array) {
        if(!expected || ![object isMemberOfClass:expected] ||
            ![object respondsToSelector:@selector(dataType)] || ![object respondsToSelector:@selector(data)] ||
            ![object respondsToSelector:indexed?@selector(index):@selector(name)])
            return reject(error,@"unexpected typed constant record");
        id<A5MaliRequestConstantRecord> entry=object;
        NSUInteger type=entry.dataType,bytes=constantBytes(type);
        if(!bytes || !entry.data)return reject(error,@"unsupported or unavailable constant data");
        id key=indexed?@(entry.index):entry.name;
        if((indexed&&entry.index>65535)||(!indexed&&!identifier(key))||[seen containsObject:key])
            return reject(error,@"invalid or duplicate constant key");
        [seen addObject:key];
        uint8_t copied[32];memcpy(copied,entry.data,bytes);char raw[65];
        for(NSUInteger i=0;i<bytes;++i)snprintf(raw+2*i,3,"%02x",copied[i]);
        raw[2*bytes]=0;
        [result addObject:@{indexed?@"index":@"name":key,@"type":@(type),
            @"bytes":@(bytes),@"raw":[NSString stringWithUTF8String:raw]}];
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        return [a[indexed?@"index":@"name"] compare:b[indexed?@"index":@"name"]];
    }];
}

NSDictionary *A5MaliShaderCompileFunctionPayload(NSString *name,MTLFunctionType stage,
    MTLFunctionConstantValues *constants,NSError **error)
{
    if(error)*error=nil;
    if(!identifier(name)||(stage!=MTLFunctionTypeVertex&&stage!=MTLFunctionTypeFragment))
        return reject(error,@"function requires an exact identifier and vertex/fragment stage");
    @try {
        NSArray *named=captureConstants(constants,NO,error);if(!named)return nil;
        NSArray *indexed=captureConstants(constants,YES,error);if(!indexed)return nil;
        NSMutableDictionary *payload=[base(@"function") mutableCopy];
        if(stage==MTLFunctionTypeFragment)payload[@"compiler_abi"]=@2;
        [payload addEntriesFromDictionary:@{@"stage":stage==MTLFunctionTypeVertex?@"vertex":@"fragment",
            @"function":[name copy],@"named_constants":named,@"indexed_constants":indexed}];
        return [payload copy];
    } @catch(NSException *exception) {
        (void)exception;return reject(error,@"constant snapshot raised an exception");
    }
}

static BOOL keysAre(NSDictionary *value,NSArray *keys)
{
    return [value isKindOfClass:NSDictionary.class]&&
        [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static BOOL uint32Value(id value)
{
    if(![value isKindOfClass:NSNumber.class])return NO;
    double n=[value doubleValue];return n>=0&&n<=UINT32_MAX&&n==(double)[value unsignedLongLongValue];
}
static BOOL validConstantArray(id values,BOOL indexed)
{
    if(![values isKindOfClass:NSArray.class]||[values count]>kMaxConstants)return NO;
    NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *v in values){
        NSString *key=indexed?@"index":@"name";
        if(!keysAre(v,@[key,@"type",@"bytes",@"raw"])||!uint32Value(v[@"type"])||
            !uint32Value(v[@"bytes"]))return NO;
        NSUInteger bytes=constantBytes([v[@"type"] unsignedIntegerValue]);
        if(!bytes||[v[@"bytes"] unsignedIntegerValue]!=bytes||
            ![v[@"raw"] isKindOfClass:NSString.class]||[v[@"raw"] length]!=2*bytes)return NO;
        const char *raw=[v[@"raw"] UTF8String];
        if(!raw||strlen(raw)!=2*bytes)return NO;
        for(NSUInteger j=0;j<2*bytes;++j)if(!((raw[j]>='0'&&raw[j]<='9')||
            (raw[j]>='a'&&raw[j]<='f')))return NO;
        if(indexed?(!uint32Value(v[key])||[v[key] unsignedIntegerValue]>65535):!identifier(v[key]))return NO;
        if([seen containsObject:v[key]])return NO;[seen addObject:v[key]];
    }
    return YES;
}
static BOOL functionPayload(NSDictionary *value,NSString *stage)
{
    NSMutableDictionary *plain=[value isKindOfClass:NSDictionary.class]?[value mutableCopy]:nil;
    id blend=plain[@"blend_state"];[plain removeObjectForKey:@"blend_state"];
    if(blend&&(![stage isEqual:@"fragment"]||!A5MaliValidBlendRequest(blend)))return NO;
    return keysAre(plain,@[@"schema",@"kind",@"source_library",@"metallib_sha256",@"gpu_id",@"compiler_abi",
        @"stage",@"function",@"named_constants",@"indexed_constants"])&&[value[@"kind"] isEqual:@"function"]&&
        [value[@"schema"] isEqual:@1]&&([value[@"compiler_abi"] isEqual:@1]||
        ([stage isEqual:@"fragment"]&&[value[@"compiler_abi"] isEqual:@2]))&&
        [value[@"source_library"] isEqual:@"quartzcore"]&&[value[@"metallib_sha256"] isEqual:sourceSHA]&&
        [value[@"gpu_id"] isEqual:@"07201000"]&&[value[@"stage"] isEqual:stage]&&
        identifier(value[@"function"])&&validConstantArray(value[@"named_constants"],NO)&&
        validConstantArray(value[@"indexed_constants"],YES);
}
static BOOL numericRecord(NSDictionary *value,NSArray *keys)
{
    if(!keysAre(value,keys))return NO;
    for(NSString *key in keys)if(!uint32Value(value[key]))return NO;
    return YES;
}
static BOOL validDescriptor(NSDictionary *d)
{
    NSArray *scalarKeys=@[@"vertex_descriptor_present",@"raster_sample_count",@"alpha_to_coverage",@"alpha_to_one",
        @"rasterization_enabled",@"max_vertex_amplification_count",@"depth_format",@"stencil_format",
        @"input_primitive_topology",@"support_indirect_commands",@"tessellation_partition_mode",
        @"max_tessellation_factor",@"tessellation_factor_scale",@"tessellation_factor_format",
        @"tessellation_control_point_index_type",@"tessellation_factor_step_function",@"tessellation_output_winding_order",
        @"support_adding_vertex_binary_functions",@"support_adding_fragment_binary_functions",
        @"max_vertex_call_stack_depth",@"max_fragment_call_stack_depth"];
    NSArray *arrayKeys=@[@"color_attachments",@"vertex_attributes",@"vertex_layouts",@"buffer_mutability"];
    if(!keysAre(d,[scalarKeys arrayByAddingObjectsFromArray:arrayKeys]))return NO;
    for(NSString *key in scalarKeys)if(!uint32Value(d[key]))return NO;
    for(NSString *key in arrayKeys)if(![d[key] isKindOfClass:NSArray.class])return NO;
    if([d[@"color_attachments"] count]!=8||[d[@"buffer_mutability"] count]!=31)return NO;
    NSUInteger vertexCount=[d[@"vertex_descriptor_present"] boolValue]?31:0;
    if([d[@"vertex_attributes"] count]!=vertexCount||[d[@"vertex_layouts"] count]!=vertexCount)return NO;
    for(NSDictionary *a in d[@"color_attachments"])if(!numericRecord(a,@[@"format",@"write_mask",@"blend_enabled",
        @"rgb_operation",@"alpha_operation",@"source_rgb",@"destination_rgb",@"source_alpha",@"destination_alpha"]))return NO;
    for(NSUInteger i=0;i<31;++i){
        NSDictionary *b=d[@"buffer_mutability"][i];
        if(!numericRecord(b,@[@"index",@"vertex_mutability",@"fragment_mutability"])||[b[@"index"] unsignedIntegerValue]!=i)return NO;
        if(i<vertexCount){
            NSDictionary *a=d[@"vertex_attributes"][i],*l=d[@"vertex_layouts"][i];
            if(!numericRecord(a,@[@"index",@"format",@"offset",@"buffer_index"])||[a[@"index"] unsignedIntegerValue]!=i||
                !numericRecord(l,@[@"index",@"stride",@"step_function",@"step_rate"])||[l[@"index"] unsignedIntegerValue]!=i)return NO;
        }
    }
    return YES;
}
NSDictionary *A5MaliShaderCompilePipelinePayload(MTLRenderPipelineDescriptor *descriptor,
    NSDictionary *vertex,NSDictionary *fragment,NSError **error)
{
    if(error)*error=nil;
    if(![descriptor isKindOfClass:MTLRenderPipelineDescriptor.class]||
        !functionPayload(vertex,@"vertex")||!functionPayload(fragment,@"fragment"))
        return reject(error,@"pipeline requires an actual descriptor and both exact function snapshots");
    @try {
        MTLRenderPipelineDescriptor *d=[descriptor copy];
        /* Linked functions and archives need additional authenticated inputs;
         * never serialize only their counts and lose actual semantics. */
        if(d.binaryArchives.count||d.vertexPreloadedLibraries.count||d.fragmentPreloadedLibraries.count||
            d.vertexLinkedFunctions.functions.count||d.vertexLinkedFunctions.binaryFunctions.count||
            d.vertexLinkedFunctions.groups.count||d.fragmentLinkedFunctions.functions.count||
            d.fragmentLinkedFunctions.binaryFunctions.count||d.fragmentLinkedFunctions.groups.count||
            ([d.vertexLinkedFunctions respondsToSelector:@selector(privateFunctions)]&&d.vertexLinkedFunctions.privateFunctions.count)||
            ([d.fragmentLinkedFunctions respondsToSelector:@selector(privateFunctions)]&&d.fragmentLinkedFunctions.privateFunctions.count))
            return reject(error,@"linked libraries/functions and archives need an explicit source contract");
        NSMutableArray *colors=[NSMutableArray array],*attributes=[NSMutableArray array],
            *layouts=[NSMutableArray array],*buffers=[NSMutableArray array];
        for(NSUInteger i=0;i<8;++i) {
            MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[i];
            [colors addObject:@{@"format":@(a.pixelFormat),@"write_mask":@(a.writeMask),
                @"blend_enabled":@(a.isBlendingEnabled),@"rgb_operation":@(a.rgbBlendOperation),
                @"alpha_operation":@(a.alphaBlendOperation),@"source_rgb":@(a.sourceRGBBlendFactor),
                @"destination_rgb":@(a.destinationRGBBlendFactor),@"source_alpha":@(a.sourceAlphaBlendFactor),
                @"destination_alpha":@(a.destinationAlphaBlendFactor)}];
        }
        for(NSUInteger i=0;i<31;++i) {
            if(d.vertexDescriptor) {
                MTLVertexAttributeDescriptor *a=d.vertexDescriptor.attributes[i];
                MTLVertexBufferLayoutDescriptor *l=d.vertexDescriptor.layouts[i];
                [attributes addObject:@{@"index":@(i),@"format":@(a.format),@"offset":@(a.offset),@"buffer_index":@(a.bufferIndex)}];
                [layouts addObject:@{@"index":@(i),@"stride":@(l.stride),@"step_function":@(l.stepFunction),@"step_rate":@(l.stepRate)}];
            }
            [buffers addObject:@{@"index":@(i),@"vertex_mutability":@(d.vertexBuffers[i].mutability),
                @"fragment_mutability":@(d.fragmentBuffers[i].mutability)}];
        }
        NSDictionary *state=@{@"color_attachments":colors,@"vertex_descriptor_present":@(d.vertexDescriptor!=nil),
            @"vertex_attributes":attributes,@"vertex_layouts":layouts,@"buffer_mutability":buffers,
            @"raster_sample_count":@(d.rasterSampleCount),@"alpha_to_coverage":@(d.isAlphaToCoverageEnabled),
            @"alpha_to_one":@(d.isAlphaToOneEnabled),@"rasterization_enabled":@(d.isRasterizationEnabled),
            @"max_vertex_amplification_count":@(d.maxVertexAmplificationCount),
            @"depth_format":@(d.depthAttachmentPixelFormat),@"stencil_format":@(d.stencilAttachmentPixelFormat),
            @"input_primitive_topology":@(d.inputPrimitiveTopology),@"support_indirect_commands":@(d.supportIndirectCommandBuffers),
            @"tessellation_partition_mode":@(d.tessellationPartitionMode),@"max_tessellation_factor":@(d.maxTessellationFactor),
            @"tessellation_factor_scale":@(d.isTessellationFactorScaleEnabled),@"tessellation_factor_format":@(d.tessellationFactorFormat),
            @"tessellation_control_point_index_type":@(d.tessellationControlPointIndexType),
            @"tessellation_factor_step_function":@(d.tessellationFactorStepFunction),
            @"tessellation_output_winding_order":@(d.tessellationOutputWindingOrder),
            @"support_adding_vertex_binary_functions":@(d.supportAddingVertexBinaryFunctions),
            @"support_adding_fragment_binary_functions":@(d.supportAddingFragmentBinaryFunctions),
            @"max_vertex_call_stack_depth":@(d.maxVertexCallStackDepth),@"max_fragment_call_stack_depth":@(d.maxFragmentCallStackDepth)};
        NSMutableDictionary *payload=[base(@"pipeline") mutableCopy];
        [payload addEntriesFromDictionary:@{@"vertex":vertex,@"fragment":fragment,@"descriptor":state}];
        if(!validDescriptor(state))return reject(error,@"pipeline descriptor exceeds the bounded scalar contract");
        /* JSON round-trip also deep-copies all caller containers. */
        NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:error];
        return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;
    } @catch(NSException *exception) {
        (void)exception;return reject(error,@"pipeline snapshot raised an exception");
    }
}

static NSString *sha256(NSData *data)
{
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    char text[65];for(unsigned i=0;i<sizeof(bytes);++i)snprintf(text+2*i,3,"%02x",bytes[i]);
    return [NSString stringWithUTF8String:text];
}
static BOOL safeFile(int fd,uid_t uid)
{
    struct stat st;return fd>=0&&!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==uid&&
        (st.st_mode&0777)==0600&&st.st_nlink==1&&st.st_size<=kMaxRequestBytes;
}
static BOOL fullWrite(int fd,const void *bytes,size_t size)
{
    const char *p=bytes;while(size){ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;
        if(n<=0)return NO;p+=n;size-=(size_t)n;}return YES;
}
static BOOL equalFile(int fd,NSData *data)
{
    struct stat st;if(fstat(fd,&st)||st.st_size!=(off_t)data.length)return NO;
    uint8_t b[4096];size_t offset=0;
    while(offset<data.length){ssize_t n=read(fd,b,MIN(sizeof(b),data.length-offset));
        if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(b,(const uint8_t *)data.bytes+offset,(size_t)n))return NO;offset+=(size_t)n;}
    return YES;
}
static NSData *requestData(NSDictionary *payload,NSString **requestID,NSError **error)
{
    if(error)*error=nil;if(requestID)*requestID=nil;
    if(![payload isKindOfClass:NSDictionary.class]){
        reject(error,@"invalid compiler request envelope");return nil;
    }
    BOOL function=[payload[@"kind"] isEqual:@"function"];
    BOOL valid=function?(functionPayload(payload,@"vertex")||functionPayload(payload,@"fragment")):
        (keysAre(payload,@[@"schema",@"kind",@"source_library",@"metallib_sha256",@"gpu_id",@"compiler_abi",
            @"vertex",@"fragment",@"descriptor"])&&[payload[@"kind"] isEqual:@"pipeline"]&&
         functionPayload(payload[@"vertex"],@"vertex")&&functionPayload(payload[@"fragment"],@"fragment")&&
         validDescriptor(payload[@"descriptor"]));
    if(!valid||![payload[@"schema"] isEqual:@1]||![payload[@"source_library"] isEqual:@"quartzcore"]||
        ![payload[@"metallib_sha256"] isEqual:sourceSHA]||![payload[@"gpu_id"] isEqual:@"07201000"]||
        (![payload[@"compiler_abi"] isEqual:@1]&&!(function&&[payload[@"stage"] isEqual:@"fragment"]&&[payload[@"compiler_abi"] isEqual:@2]))||payload[@"request_id"]||payload[@"owner_uid"]){
        reject(error,@"invalid compiler request envelope");return nil;
    }
    uid_t uid=geteuid();NSMutableDictionary *body=[payload mutableCopy];body[@"owner_uid"]=@(uid);
    NSData *canonical=[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:error];
    if(!canonical||canonical.length>kMaxRequestBytes-128){reject(error,@"request exceeds128KiB");return nil;}
    NSString *key=sha256(canonical);body[@"request_id"]=key;
    NSData *data=[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:error];
    if(!data||data.length>kMaxRequestBytes){reject(error,@"request exceeds128KiB");return nil;}
    if(requestID)*requestID=key;
    return data;
}
NSString *A5MaliShaderCompileRequestID(NSDictionary *payload,NSError **error)
{
    NSString *key=nil;
    return requestData(payload,&key,error)?key:nil;
}
A5MaliShaderForwardResult A5MaliForwardShaderCompileRequest(NSDictionary *payload,
    NSString **requestID,NSError **error)
{
    if(requestID)*requestID=nil;
    NSString *key=nil;NSData *data=requestData(payload,&key,error);
    if(!data)return A5MaliShaderForwardFailed;
    uid_t uid=geteuid();
    int root=-1,dir=-1,lock=-1,file=-1;BOOL created=NO;NSString *temp=nil;
    NSString *name=[key stringByAppendingString:@".request.json"];
    A5MaliShaderForwardResult result=A5MaliShaderForwardFailed;NSString *reason=@"spool unavailable";
    root=open(spoolRoot,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);struct stat st;
    if(root<0||fstat(root,&st)||!S_ISDIR(st.st_mode)||(st.st_mode&07777)!=01777)goto done;
#ifndef A5_SHADER_REQUEST_HOST_TEST
    if(st.st_uid!=0)goto done;
#else
    if(st.st_uid!=uid)goto done;
#endif
    dir=A5MaliOpenShaderLane(root,uid,[payload[@"kind"] isEqual:@"function"],1);
    if(dir<0)goto done;
    lock=openat(dir,".lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if(!safeFile(lock,uid))goto done;
    if(flock(lock,LOCK_EX|LOCK_NB)){
        if(errno==EWOULDBLOCK||errno==EAGAIN)result=A5MaliShaderForwardBusy;
        goto done;
    }
    file=openat(dir,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if(file>=0){
        if(!safeFile(file,uid)||!equalFile(file,data)){reason=@"existing request identity/content mismatch";goto done;}
        result=A5MaliShaderForwardAlreadyQueued;goto done;
    }
    if(errno!=ENOENT)goto done;
    int scanfd=dup(dir);if(scanfd<0)goto done;
    DIR *entries=fdopendir(scanfd);if(!entries){close(scanfd);goto done;}
    unsigned count=0;struct dirent *entry;
    while((entry=readdir(entries)))if(entry->d_name[0]!='.'&&strcmp(entry->d_name,"functions")&&++count>=kMaxPending)break;
    closedir(entries);
    if(count>=kMaxPending){result=A5MaliShaderForwardBusy;goto done;}
    static atomic_uint serial;unsigned next=atomic_fetch_add_explicit(&serial,1,memory_order_relaxed);
    temp=[NSString stringWithFormat:@".tmp-%d-%u-%08x",getpid(),next,arc4random()];
    file=openat(dir,temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(file<0)goto done;created=YES;
    if(!safeFile(file,uid)||!fullWrite(file,data.bytes,data.length)||fsync(file)){
        reason=@"request write/sync failed";goto done;}
    if(close(file)){file=-1;goto done;}file=-1;
    if(renameat(dir,temp.fileSystemRepresentation,dir,name.fileSystemRepresentation)||fsync(dir)){
        reason=@"request publication/sync failed";goto done;}
    created=NO;result=A5MaliShaderForwardQueued;
done:
    if(file>=0)close(file);
    if(created&&dir>=0)unlinkat(dir,temp.fileSystemRepresentation,0);
    if(lock>=0)close(lock);if(dir>=0)close(dir);if(root>=0)close(root);
    if(result!=A5MaliShaderForwardFailed){if(requestID)*requestID=key;}
    else reject(error,reason);
    return result;
}
