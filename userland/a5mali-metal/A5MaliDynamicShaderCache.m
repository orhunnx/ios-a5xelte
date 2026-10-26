/* SPDX-License-Identifier: MIT
 * Root-published single stages. Reflection describes executable ABI, not a
 * promise that the current render encoder supports every translated feature.
 */
#import "A5MaliDynamicShaderCache.h"
#import "A5MaliBlendRequest.h"
#import "A5MaliImmutableSampler.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef A5_DYNAMIC_SHADER_CACHE_HOST_TEST
static const char *const cacheRoot = "/private/var/tmp/a5mali-shader-compiled";
static uid_t expectedUID(void) { return 0; }
#else
#ifndef A5_DYNAMIC_SHADER_CACHE_TEST_ROOT
#error "Dynamic cache tests require explicit private root"
#endif
static const char *const cacheRoot = A5_DYNAMIC_SHADER_CACHE_TEST_ROOT;
extern uid_t A5MaliDynamicShaderCacheTestUID(void);
static uid_t expectedUID(void) { return A5MaliDynamicShaderCacheTestUID(); }
#endif
static NSString *const librarySHA = @"11c74cc42ce5137b73d44d427f75764f886656d4ddb374422d56b609ed2762d9";
static id fail(NSError **error, int code, NSString *why) {
    if (error)
        *error = [NSError errorWithDomain:@"com.orhunnx.a5xelte.dynamic-shader"
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : why}];
    return nil;
}
static BOOL number(id o, uint64_t max) {
    return [o isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)o) != CFBooleanGetTypeID() &&
           !CFNumberIsFloatType((__bridge CFNumberRef)o) && [o longLongValue] >= 0 &&
           [o unsignedLongLongValue] <= max;
}
static BOOL exact(id o, uint64_t n) { return number(o, n) && [o unsignedLongLongValue] == n; }
static BOOL boolean(id o, BOOL n) {
    return o && CFGetTypeID((__bridge CFTypeRef)o) == CFBooleanGetTypeID() && [o boolValue] == n;
}
static BOOL hex(id o, NSUInteger n) {
    if (![o isKindOfClass:NSString.class] || [o length] != n)
        return NO;
    const char *p = [o UTF8String];
    if (!p || strlen(p) != n)
        return NO;
    for (NSUInteger i = 0; i < n; i++)
        if (!((p[i] >= '0' && p[i] <= '9') || (p[i] >= 'a' && p[i] <= 'f')))
            return NO;
    return YES;
}
static BOOL identifier(id o) {
    if (![o isKindOfClass:NSString.class] || ![o length] || [o length] > 128)
        return NO;
    const char *p = [o UTF8String];
    if (!p || strlen(p) != [o length])
        return NO;
    for (; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '_'))
            return NO;
    return YES;
}
static NSString *digest(NSData *d) {
    unsigned char b[32];
    CC_SHA256(d.bytes, (CC_LONG)d.length, b);
    char s[65];
    for (unsigned i = 0; i < 32; i++)
        snprintf(s + i * 2, 3, "%02x", b[i]);
    return [NSString stringWithUTF8String:s];
}
static NSData *json(id o) {
    return [NSJSONSerialization isValidJSONObject:o]
               ? [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:NULL]
               : nil;
}
static BOOL keys(id o, NSArray *k) {
    return [o isKindOfClass:NSDictionary.class] &&
           [[NSSet setWithArray:[o allKeys]] isEqual:[NSSet setWithArray:k]];
}
static BOOL directory(int fd) {
    struct stat s;
    return fd >= 0 && !fstat(fd, &s) && S_ISDIR(s.st_mode) && s.st_uid == expectedUID() &&
           (s.st_mode & 07777) == 0755;
}
static NSData *readFile(int parent, const char *name, size_t maximum, NSError **error) {
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW);
    if (fd < 0)
        return fail(error, errno == ENOENT ? ENOENT : EIO, @"published stage file unavailable");
    struct stat a, b;
    if (fstat(fd, &a) || !S_ISREG(a.st_mode) || a.st_uid != expectedUID() || (a.st_mode & 07777) != 0444 ||
        a.st_nlink != 1 || a.st_size <= 0 || (uint64_t)a.st_size > maximum) {
        close(fd);
        return fail(error, EINVAL, @"stage file ownership/mode/size rejected");
    }
    NSMutableData *d = [NSMutableData dataWithLength:a.st_size];
    size_t at = 0;
    while (at < d.length) {
        ssize_t n = read(fd, (uint8_t *)d.mutableBytes + at, d.length - at);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            close(fd);
            return fail(error, EIO, @"stage file read failed");
        }
        at += n;
    }
    BOOL changed =
        fstat(fd, &b) || a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size ||
        a.st_mtimespec.tv_sec != b.st_mtimespec.tv_sec || a.st_mtimespec.tv_nsec != b.st_mtimespec.tv_nsec ||
        a.st_ctimespec.tv_sec != b.st_ctimespec.tv_sec || a.st_ctimespec.tv_nsec != b.st_ctimespec.tv_nsec ||
        b.st_uid != expectedUID() || (b.st_mode & 07777) != 0444 || b.st_nlink != 1;
    int closed = close(fd);
    if (changed || closed)
        return fail(error, EIO, @"stage file changed during read");
    return [d copy];
}
static NSUInteger constantBytes(NSUInteger t) {
    if (t >= 3 && t <= 6)
        return 4 * (t - 2);
    if (t >= 16 && t <= 19)
        return 2 * (t - 15);
    if (t >= 29 && t <= 36)
        return 4 * (1 + (t - 29) % 4);
    if (t >= 37 && t <= 44)
        return 2 * (1 + (t - 37) % 4);
    if (t >= 45 && t <= 56)
        return 1 + (t - 45) % 4;
    if (t >= 81 && t <= 88)
        return 8 * (1 + (t - 81) % 4);
    return 0;
}
static BOOL constants(id a, BOOL indexed) {
    if (![a isKindOfClass:NSArray.class] || [a count] > 64)
        return NO;
    id previous = nil;
    for (id c in a) {
        NSString *k = indexed ? @"index" : @"name";
        if (!keys(c, @[ k, @"type", @"bytes", @"raw" ]) || !number(c[@"type"], UINT32_MAX))
            return NO;
        NSUInteger n = constantBytes([c[@"type"] unsignedIntegerValue]);
        if (!n || !exact(c[@"bytes"], n) || !hex(c[@"raw"], 2 * n) ||
            (indexed ? !number(c[k], 65535) : !identifier(c[k])))
            return NO;
        if (previous && [previous compare:c[k]] != NSOrderedAscending)
            return NO;
        previous = c[k];
    }
    return YES;
}
static BOOL payload(id p) {
    NSMutableDictionary *plain=[p isKindOfClass:NSDictionary.class]?[p mutableCopy]:nil;
    id blend=plain[@"blend_state"];[plain removeObjectForKey:@"blend_state"];
    if(blend&&(![p[@"stage"] isEqual:@"fragment"]||!A5MaliValidBlendRequest(blend)))return NO;
    return keys(plain,
                @[
                    @"schema", @"kind", @"source_library", @"metallib_sha256", @"gpu_id", @"compiler_abi",
                    @"stage", @"function", @"named_constants", @"indexed_constants"
                ]) &&
           exact(p[@"schema"], 1) && [p[@"kind"] isEqual:@"function"] &&
           [p[@"source_library"] isEqual:@"quartzcore"] && [p[@"metallib_sha256"] isEqual:librarySHA] &&
           [p[@"gpu_id"] isEqual:@"07201000"] && (exact(p[@"compiler_abi"], 1)||([p[@"stage"] isEqual:@"fragment"]&&exact(p[@"compiler_abi"],2))) &&
           ([p[@"stage"] isEqual:@"vertex"] || [p[@"stage"] isEqual:@"fragment"]) &&
           identifier(p[@"function"]) && constants(p[@"named_constants"], NO) &&
           constants(p[@"indexed_constants"], YES);
}

@interface A5MaliDynamicShaderCacheEntry ()
- (instancetype)initWithRequest:(NSString *)request
                        payload:(NSDictionary *)payload
                        receipt:(NSDictionary *)receipt
                           code:(NSData *)code
                     reflection:(NSDictionary *)reflection;
- (BOOL)deriveABI;
@end
@implementation A5MaliDynamicShaderCacheEntry {
    NSData *_code;
    NSString *_codeSHA, *_requestID, *_functionName;
    NSDictionary *_functionPayload, *_nativeABI, *_reflection;
    A5MaliCompiledShader _shader;
    A5MaliCompiledResource _resources[32];
    A5MaliCompiledSampler _immutableSamplers[4];
    uint32_t _immutableSamplerCount;
    A5MaliCompiledPushField _pushFields[32];
    A5MaliCompiledVertexAttribute _attributes[16];
    A5MaliCompiledVertexLayout _layouts[16];
    uint32_t _resourceCount, _pushFieldCount, _attributeCount, _layoutCount, _stage;
}
- (instancetype)initWithRequest:(NSString *)request
                        payload:(NSDictionary *)p
                        receipt:(NSDictionary *)r
                           code:(NSData *)code
                     reflection:(NSDictionary *)reflection {
    if ((self = [super init])) {
        _requestID = [request copy];
        _functionPayload = [NSJSONSerialization JSONObjectWithData:json(p) options:0 error:NULL];
        _functionName = [p[@"function"] copy];
        _nativeABI = r[@"native_abi"];
        _reflection = reflection;
        _code = [code copy];
        _codeSHA = [r[@"native"][@"sha256"] copy];
        NSDictionary *n = r[@"native"];
        _shader = (A5MaliCompiledShader){_code.bytes,
                                         (uint32_t)_code.length,
                                         [n[@"first_tag"] unsignedIntValue],
                                         [n[@"work_registers"] unsignedIntValue],
                                         [n[@"tls_bytes"] unsignedIntValue],
                                         [n[@"wls_bytes"] unsignedIntValue],
                                         _codeSHA.UTF8String};
        _stage = [p[@"stage"] isEqual:@"vertex"] ? 1 : 2;
    }
    return self;
}
- (const A5MaliCompiledShader *)shader {
    return &_shader;
}
- (const A5MaliCompiledResource *)resources {
    return _resources;
}
- (uint32_t)resourceCount {
    return _resourceCount;
}
- (const A5MaliCompiledSampler *)immutableSamplers { return _immutableSamplers; }
- (uint32_t)immutableSamplerCount { return _immutableSamplerCount; }
- (const A5MaliCompiledPushField *)pushFields {
    return _pushFields;
}
- (uint32_t)pushFieldCount {
    return _pushFieldCount;
}
- (const A5MaliCompiledVertexAttribute *)attributes {
    return _attributes;
}
- (uint32_t)attributeCount {
    return _attributeCount;
}
- (const A5MaliCompiledVertexLayout *)layouts {
    return _layouts;
}
- (uint32_t)layoutCount {
    return _layoutCount;
}
- (uint32_t)stage {
    return _stage;
}
- (NSString *)requestID {
    return _requestID;
}
- (NSString *)functionName {
    return _functionName;
}
- (NSDictionary *)functionPayload {
    return _functionPayload;
}
- (NSDictionary *)nativeABI {
    return _nativeABI;
}
- (NSDictionary *)reflection {
    return _reflection;
}
- (BOOL)deriveABI {
    NSDictionary *a = _nativeABI;
    NSString *stageName = _stage == 1 ? @"Vertex" : @"Fragment";
    if (![a isKindOfClass:NSDictionary.class] || !exact(a[@"schema"], 1) ||
        ![a[@"stage"] isEqual:(_stage == 1 ? @"vertex" : @"fragment")] ||
        !number(a[@"sysval_ubo0_read_extent"], 576))
        return NO;
    if([_functionPayload[@"compiler_abi"] isEqual:@2] && !exact(a[@"shader_anisotropy"],1))return NO;
    NSDictionary *info = a[@"native_info"];
    if (![info isKindOfClass:NSDictionary.class] || !exact(info[@"bytes"], _shader.byteCount) ||
        !exact(info[@"first_tag"], _shader.firstTag) || !exact(info[@"work_regs"], _shader.workRegisters) ||
        !exact(info[@"tls"], 0) || !exact(info[@"wls"], 0) || !number(info[@"attributes"], 16) ||
        !number(info[@"ubos"], 8) || !number(info[@"textures"], 8) || !number(info[@"samplers"], 8))
        return NO;
    for (NSString *k in @[ @"inputs", @"outputs" ]) {
        id arr = a[k];
        if (![arr isKindOfClass:NSArray.class] || [arr count] > 32)
            return NO;
        NSMutableDictionary *bases = [NSMutableDictionary new];
        for (id v in arr) {
            if (![v isKindOfClass:NSDictionary.class])
                return NO;
            for (NSString *f in @[ @"location", @"base", @"component", @"components", @"bit_size" ])
                if (!number(v[f], [f isEqual:@"location"] ? 127 : 64))
                    return NO;
            if (![v[@"components"] unsignedIntValue] || [v[@"components"] unsignedIntValue] > 4 ||
                [v[@"component"] unsignedIntValue] > 3 ||
                [v[@"components"] unsignedIntValue] + [v[@"component"] unsignedIntValue] > 4 ||
                !exact(v[@"bit_size"], 32))
                return NO;
            /* Optimized NIR may load X and XY separately. Overlapping
             * lanes are valid, but one location cannot change hardware base. */
            NSNumber *previous = bases[v[@"location"]];
            if (previous && ![previous isEqual:v[@"base"]])
                return NO;
            bases[v[@"location"]] = v[@"base"];
        }
    }
    id liveUBOs = a[@"live_ubos"], liveTextures = a[@"live_textures"];
    if (![liveUBOs isKindOfClass:NSArray.class] || [liveUBOs count] > 8 ||
        ![liveTextures isKindOfClass:NSArray.class] || [liveTextures count] > 8)
        return NO;
    NSMutableDictionary *live = [NSMutableDictionary new], *logical = [NSMutableDictionary new];
    for (id v in liveUBOs) {
        if (!(keys(v, @[ @"native_index", @"min_bytes" ]) || keys(v,@[@"native_index",@"min_bytes",@"logical_bytes"])) || !number(v[@"native_index"], 7) ||
            !number(v[@"min_bytes"], 4096) || ![v[@"min_bytes"] unsignedIntValue] || live[v[@"native_index"]])
            return NO;
        live[v[@"native_index"]] = v[@"min_bytes"];
        if(v[@"logical_bytes"]){
            unsigned n=[v[@"logical_bytes"] unsignedIntValue],physical=[v[@"min_bytes"] unsignedIntValue];
            if(!number(v[@"logical_bytes"],4096)||!n||!(n&3)||((n+3)&~3u)!=physical||
               ![v[@"native_index"] unsignedIntValue])return NO;
            logical[v[@"native_index"]]=v[@"logical_bytes"];
        }
    }
    if ([live[@0] unsignedIntValue] != [a[@"sysval_ubo0_read_extent"] unsignedIntValue])
        return NO;
    for (NSNumber *index in live)
        if (index.unsignedIntValue >= [info[@"ubos"] unsignedIntValue])
            return NO;
    NSMutableSet *textures = [NSMutableSet new];
    for (id v in liveTextures) {
        if (!number(v, 7) || [textures containsObject:v])
            return NO;
        if ([v unsignedIntValue] >= [info[@"textures"] unsignedIntValue] ||
            [v unsignedIntValue] >= [info[@"samplers"] unsignedIntValue])
            return NO;
        [textures addObject:v];
    }
    id sets = _reflection[@"layout"][@"sets"], slots = _reflection[@"interface"][@"slots"],
       pushes = _reflection[@"interface"][@"push"];
    if (![sets isKindOfClass:NSArray.class] || [sets count] > 1 || ![slots isKindOfClass:NSArray.class] ||
        [slots count] > 64 || ![pushes isKindOfClass:NSArray.class] || [pushes count] > 2)
        return NO;
    NSMutableDictionary *pushOffsets = [NSMutableDictionary new];
    for (id block in pushes) {
        if (![block isKindOfClass:NSDictionary.class])
            return NO;
        if (![block[@"stage"] isEqual:stageName])
            continue;
        if (![block[@"fields"] isKindOfClass:NSArray.class] || [block[@"fields"] count] > 32)
            return NO;
        for (id f in block[@"fields"]) {
            if (![f isKindOfClass:NSDictionary.class] || !exact(f[@"size"], 4) ||
                !number(f[@"loc"][@"Push"][@"offset"], 76) ||
                ([f[@"loc"][@"Push"][@"offset"] unsignedIntValue] & 3))
                return NO;
            id bind = f[@"field"][@"SlotBindOffset"];
            if (bind) {
                if (![bind[@"stage"] isEqual:stageName] || ![bind[@"class"] isEqual:@"Buffer"] ||
                    !number(bind[@"index"], 30) || pushOffsets[bind[@"index"]])
                    return NO;
                pushOffsets[bind[@"index"]] = f[@"loc"][@"Push"][@"offset"];
                continue;
            }
            id rule = f[@"field"][@"ColorWriteRule"];
            if (!rule || _stage != 2 || !number(rule, 7))
                return NO;
            id rules = _reflection[@"graphics"][@"color_write_rules"];
            NSNumber *value = nil;
            for (id pair in rules) {
                if (![pair isKindOfClass:NSArray.class] || [pair count] != 2)
                    return NO;
                if ([pair[0] isEqual:rule]) {
                    if (!number(pair[1], UINT32_MAX))
                        return NO;
                    value = pair[1];
                }
            }
            if (!value || _pushFieldCount == 32)
                return NO;
            _pushFields[_pushFieldCount++] = (A5MaliCompiledPushField){
                _stage, A5MaliPushColorWriteRule, 0, [f[@"loc"][@"Push"][@"offset"] unsignedIntValue],
                4,      value.unsignedIntValue};
        }
    }
    NSMutableSet *usedUBOs = [NSMutableSet setWithObject:@0], *usedTextures = [NSMutableSet new],
                 *seenBindings = [NSMutableSet new];
    unsigned textureIndex = 0, fetches = 0;
    BOOL lowered=_functionPayload[@"blend_state"]!=nil;
    if(lowered!=boolean(a[@"blend_lowered"],YES) ||
       (a[@"blend_lowered"]&&!boolean(a[@"blend_lowered"],YES)))return NO;
    id fetchABI=a[@"framebuffer_fetch"];
    if(fetchABI&&!boolean(fetchABI,YES)&&!boolean(fetchABI,NO))return NO;
    BOOL fetch=boolean(fetchABI,YES);
    if(fetch&&_stage!=2)return NO;
    for (id set in sets) {
        if (!exact(set[@"set"], 0) || ![set[@"bindings"] isKindOfClass:NSArray.class] ||
            [set[@"bindings"] count] > 32)
            return NO;
        for (id b in set[@"bindings"]) {
            if (![b isKindOfClass:NSDictionary.class] || !number(b[@"binding"], 31) ||
                [seenBindings containsObject:b[@"binding"]] || !exact(b[@"count"], 1) ||
                !number(b[@"stages"], 31))
                return NO;
            [seenBindings addObject:b[@"binding"]];
            unsigned stageBit = _stage == 1 ? 1 : 16;
            if (!([b[@"stages"] unsignedIntValue] & stageBit))
                continue;
            if (!exact(b[@"flags"], 0))
                return NO;
            NSDictionary *source = b[@"source"];
            if (![source isKindOfClass:NSDictionary.class])
                return NO;
            id buffer = source[@"Buffer"];
            if (buffer) {
                unsigned native = [b[@"binding"] unsignedIntValue] + 1;
                NSNumber *extent = live[@(native)],*logicalExtent=logical[@(native)]?:extent;
                if (!extent)
                    continue;
                if (native > 7 || !exact(b[@"ty"], 6) || ![buffer[@"stage"] isEqual:stageName] ||
                    ![buffer[@"class"] isEqual:@"Buffer"] || !number(buffer[@"index"], 30) ||
                    !pushOffsets[buffer[@"index"]] || _resourceCount == 32 || _pushFieldCount == 32)
                    return NO;
                NSDictionary *contract = nil;
                for (id slot in slots) {
                    if (![slot isKindOfClass:NSArray.class] || [slot count] != 2)
                        return NO;
                    if ([slot[0] isEqual:buffer])
                        contract = slot[1][@"Buffer"];
                }
                if (![contract isKindOfClass:NSDictionary.class] ||
                    !boolean(contract[@"access"][@"read"], YES) ||
                    !boolean(contract[@"access"][@"write"], NO) ||
                    ![contract[@"form"][@"Descriptor"] isEqual:@"UniformWords"] ||
                    !exact(contract[@"window"][@"Bounded"][@"start"], 0) ||
                    !number(contract[@"window"][@"Bounded"][@"len"], 65536) ||
                    [contract[@"window"][@"Bounded"][@"len"] unsignedIntValue] < logicalExtent.unsignedIntValue)
                    return NO;
                unsigned metal = [buffer[@"index"] unsignedIntValue],
                         push = [pushOffsets[@(metal)] unsignedIntValue];
                _resources[_resourceCount++] =
                    (A5MaliCompiledResource){_stage, A5MaliResourceBuffer,
                                             metal,  [b[@"binding"] unsignedIntValue],
                                             native, A5MaliResourceRead|(logical[@(native)]?A5MaliResourcePadUniformTail:0),
                                             0,      logicalExtent.unsignedIntValue,
                                             0,      push};
                _pushFields[_pushFieldCount++] =
                    (A5MaliCompiledPushField){_stage, A5MaliPushBindOffset, metal, push, 4, 0};
                [usedUBOs addObject:@(native)];
                continue;
            }
            if(source[@"Synthetic"]){
                /* Released-Mesa dynamic inspection rejects every surviving
                 * global/SSBO access and every FS UBO0 load outside push0..80
                 * or the independently checked per-texture sysval records.
                 * A declared ConstantBlob may therefore be omitted only for
                 * this explicitly dead, bounded fragment contract. It is not
                 * an application buffer slot or a source of zero-filled data. */
                id synthetic=source[@"Synthetic"];
                if(_stage!=2||!keys(source,@[@"Synthetic"])||
                   !keys(synthetic,@[@"stage",@"binding"])||
                   ![synthetic[@"stage"] isEqual:stageName]||
                   ![synthetic[@"binding"] isEqual:@"ConstantBlob"]||
                   !exact(b[@"ty"],7)||live[@([b[@"binding"] unsignedIntValue]+1)]||
                   ([a[@"sysval_ubo0_read_extent"] unsignedIntValue]>80&&
                    !(lowered&&[a[@"sysval_ubo0_read_extent"] unsignedIntValue]<=496)&&
                    !(exact(a[@"shader_anisotropy"],1)&&[a[@"sysval_ubo0_read_extent"] unsignedIntValue]<=480)))return NO;
                NSString *blob=nil;unsigned matching=0;
                for(id stage in _reflection[@"stages"])if([stage[@"stage"] isEqual:@"frag"]){blob=stage[@"constant_blob"];matching++;}
                if(matching!=1||![blob isKindOfClass:NSString.class]||!blob.length||
                   (blob.length&1)||blob.length>8192||!hex(blob,blob.length))return NO;
                continue;
            }
            if(source[@"InputAttachment"]){
                NSDictionary *g=_reflection[@"graphics"];
                if(!fetch||fetches++||!exact(source[@"InputAttachment"],0)||
                   !exact(b[@"ty"],10)||!boolean(g[@"rasterization_order_attachment_access"],YES)||
                   !exact(g[@"rasterization_samples"],1)||
                   ![g[@"input_attachments"] isEqual:@[@{@"color_index":@0,@"input_attachment_index":@0,@"format_class":@"Float"}]]||
                   _resourceCount==32)return NO;
                _resources[_resourceCount++]=(A5MaliCompiledResource){
                    2,A5MaliResourceInputAttachment,0,[b[@"binding"] unsignedIntValue],0,A5MaliResourceRead,0,0,0,0};
                continue;
            }
            id combined = source[@"CombinedTextureSampler"];
            if (combined) {
                unsigned native = textureIndex++;
                if (![textures containsObject:@(native)])
                    continue;
                NSDictionary *t = combined[@"texture"], *s = combined[@"sampler"];
                id immutable=b[@"immutable_sampler"],token=s[@"sampler"][@"Constexpr"];
                BOOL constant=immutable&&immutable!=NSNull.null;
                if(constant){
                    if(![token isKindOfClass:NSArray.class]||[token count]!=2||
                       !number(token[0],UINT64_MAX)||!number(token[1],UINT64_MAX)||_immutableSamplerCount==4||
                       !A5MaliDecodeImmutableSampler(immutable,native,_immutableSamplers+_immutableSamplerCount))return NO;
                    _immutableSamplerCount++;
                }
                if (!exact(b[@"ty"], 1) || ![t[@"stage"] isEqual:stageName] ||
                    ![t[@"class"] isEqual:@"Texture"] || !number(t[@"index"], 30) ||
                    (!constant&&!number(s[@"sampler"][@"Slot"], 30)) || !boolean(s[@"compare"], NO) ||
                    !boolean(s[@"integer"], NO) || !boolean(s[@"cube_gradient"], NO) ||
                    !boolean(s[@"raw"], NO) || (!constant&&immutable!=NSNull.null) || _resourceCount > 30)
                    return NO;
                _resources[_resourceCount++] = (A5MaliCompiledResource){_stage,
                                                                        A5MaliResourceTexture,
                                                                        [t[@"index"] unsignedIntValue],
                                                                        [b[@"binding"] unsignedIntValue],
                                                                        native,
                                                                        A5MaliResourceRead,
                                                                        0,
                                                                        0,
                                                                        0,
                                                                        0};
                _resources[_resourceCount++] =
                    (A5MaliCompiledResource){_stage,
                                             A5MaliResourceSampler,
                                             constant?31:[s[@"sampler"][@"Slot"] unsignedIntValue],
                                             [b[@"binding"] unsignedIntValue],
                                             native,
                                             A5MaliResourceRead|(constant?A5MaliResourceImmutableSampler:0),
                                             0,
                                             0,
                                             0,
                                             0};
                [usedTextures addObject:@(native)];
                continue;
            }
            return NO; /* no unrecognized descriptor source is ignored */
        }
    }
    for (NSNumber *k in live)
        if (![usedUBOs containsObject:k])
            return NO;
    if (fetch!=(fetches==1))return NO;
    if (![usedTextures isEqual:textures])
        return NO;
    if (_stage == 1) {
        id input = _reflection[@"vertex_input"];
        if (![input isKindOfClass:NSDictionary.class] ||
            ![input[@"attributes"] isKindOfClass:NSArray.class] || [input[@"attributes"] count] > 16 ||
            ![input[@"bindings"] isKindOfClass:NSArray.class] || [input[@"bindings"] count] > 16 ||
            [input[@"pulled"] count] || [input[@"variant_pulled"] count])
            return NO;
        NSMutableDictionary *bindings = [NSMutableDictionary new];
        for (id b in input[@"bindings"]) {
            if (!number(b[@"binding"], 15) || bindings[b[@"binding"]] || !number(b[@"buffer_index"], 30) ||
                !number(b[@"stride"][@"Static"], 4096) || ![b[@"stride"][@"Static"] unsignedIntValue] ||
                !number(b[@"input_rate"], 1) || !exact(b[@"divisor"], 1))
                return NO;
            bindings[b[@"binding"]] = b;
            _layouts[_layoutCount++] =
                (A5MaliCompiledVertexLayout){[b[@"buffer_index"] unsignedIntValue],
                                             [b[@"stride"][@"Static"] unsignedIntValue],
                                             [b[@"input_rate"] unsignedIntValue] + 1,
                                             1};
        }
        NSMutableSet *attrs = [NSMutableSet new];
        for (id a in input[@"attributes"]) {
            id b = bindings[a[@"binding"]];
            if (!b || !number(a[@"location"], 15) || [attrs containsObject:a[@"location"]] ||
                !number(a[@"offset"], 4095))
                return NO;
            unsigned vf = [a[@"format"] unsignedIntValue],
                     fmt = vf == 109   ? 31
                           : vf == 106 ? 30
                           : vf == 103 ? 29
                           : vf == 100 ? 28
                           : vf == 97  ? 27
                                       : 0,
                     bytes = fmt == 31   ? 16
                             : fmt == 30 ? 12
                             : fmt == 29 ? 8
                             : fmt == 28 ? 4
                                         : 8;
            if (!fmt || [a[@"offset"] unsignedIntValue] + bytes > [b[@"stride"][@"Static"] unsignedIntValue])
                return NO;
            [attrs addObject:a[@"location"]];
            _attributes[_attributeCount++] =
                (A5MaliCompiledVertexAttribute){[a[@"location"] unsignedIntValue],
                                                fmt,
                                                [a[@"offset"] unsignedIntValue],
                                                [b[@"buffer_index"] unsignedIntValue]};
        }
    }
    return YES;
}
@end
A5MaliDynamicShaderCacheEntry *A5MaliLoadDynamicShaderStage(NSString *requestID,
                                                            NSDictionary *functionPayload, NSError **error) {
    if (error)
        *error = nil;
    @try {
        if (!hex(requestID, 64) || !payload(functionPayload))
            return fail(error, EINVAL, @"dynamic stage needs a typed canonical function request");
        NSMutableDictionary *body = [functionPayload mutableCopy];
        body[@"owner_uid"] = @(geteuid());
        NSData *canonical = json(body);
        if (!canonical || canonical.length > 128 * 1024 || ![digest(canonical) isEqual:requestID])
            return fail(error, EINVAL, @"dynamic stage request identity mismatch");
        int root = open(cacheRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (root < 0)
            return fail(error, errno == ENOENT ? ENOENT : EIO, @"dynamic stage cache unavailable");
        if (!directory(root)) {
            close(root);
            return fail(error, EINVAL, @"dynamic cache root ownership rejected");
        }
        int dir = openat(root, requestID.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int saved = errno;
        close(root);
        if (dir < 0)
            return fail(error, saved == ENOENT ? ENOENT : EIO, @"dynamic stage not published");
        if (!directory(dir)) {
            close(dir);
            return fail(error, EINVAL, @"dynamic request directory ownership rejected");
        }
        NSData *receiptData = readFile(dir, "receipt.json", 128 * 1024, error);
        if (!receiptData) {
            close(dir);
            return nil;
        }
        id r = [NSJSONSerialization JSONObjectWithData:receiptData options:0 error:NULL];
        if (![r isKindOfClass:NSDictionary.class] || !exact(r[@"schema"], 2) ||
            ![r[@"kind"] isEqual:@"dynamic-stage"] || ![r[@"request_id"] isEqual:requestID] ||
            ![r[@"source_library"] isEqual:@"quartzcore"] || ![r[@"metallib_sha256"] isEqual:librarySHA] ||
            ![r[@"gpu_id"] isEqual:@"07201000"] || ![r[@"compiler_abi"] isEqual:functionPayload[@"compiler_abi"]] ||
            ![r[@"stage"] isEqual:functionPayload[@"stage"]] ||
            ![r[@"function"] isEqual:functionPayload[@"function"]] ||
            ![r[@"named_constants_sha256"] isEqual:digest(json(functionPayload[@"named_constants"]))] ||
            ![r[@"indexed_constants_sha256"] isEqual:digest(json(functionPayload[@"indexed_constants"]))] ||
            !boolean(r[@"pipeline_compatible"], NO) ||
            ![(r[@"blend_state"]?:NSNull.null) isEqual:(functionPayload[@"blend_state"]?:NSNull.null)]) {
            close(dir);
            return fail(error, EINVAL, @"dynamic receipt identity/source/ABI rejected");
        }
        if (boolean(r[@"stage_compiled"], NO)) {
            close(dir);
            NSString *why =
                [r[@"error"] isKindOfClass:NSString.class] ? r[@"error"] : @"stage compiler failed";
            return fail(error, ENOTSUP, [why substringToIndex:MIN(why.length, 512)]);
        }
        if (!boolean(r[@"stage_compiled"], YES)) {
            close(dir);
            return fail(error, EINVAL, @"missing compiler completion");
        }
        id n = r[@"native"], f = r[@"reflection"];
        if (![n isKindOfClass:NSDictionary.class] || ![f isKindOfClass:NSDictionary.class] ||
            ![n[@"file"] isEqual:@"stage.midgard"] || ![f[@"file"] isEqual:@"reflection.json"] ||
            !number(n[@"bytes"], [functionPayload[@"compiler_abi"] isEqual:@2]?16384:8192) || ![n[@"bytes"] unsignedIntValue] ||
            ([n[@"bytes"] unsignedIntValue] & 15) || (!number(n[@"first_tag"],15)||[n[@"first_tag"] unsignedIntValue]<2||
             [n[@"first_tag"] unsignedIntValue]==6||[n[@"first_tag"] unsignedIntValue]==7) ||
            !number(n[@"work_registers"], 16) || ![n[@"work_registers"] unsignedIntValue] ||
            !exact(n[@"tls_bytes"], 0) || !exact(n[@"wls_bytes"], 0) || !hex(n[@"sha256"], 64) ||
            !number(f[@"bytes"], 256 * 1024) || ![f[@"bytes"] unsignedIntValue] || !hex(f[@"sha256"], 64)) {
            close(dir);
            return fail(error, EINVAL, @"dynamic stage code/metadata bounds rejected");
        }
        NSData *code = readFile(dir, "stage.midgard", [functionPayload[@"compiler_abi"] isEqual:@2]?16384:8192, error);
        NSData *reflect = code ? readFile(dir, "reflection.json", 256 * 1024, error) : nil;
        close(dir);
        if (!code || !reflect) {
            /* A successful receipt is published atomically with both files.
             * Missing artifacts are terminal, not another pending request. */
            if (error && (*error).code == ENOENT)
                return fail(error, EIO, @"completed dynamic publication is missing an artifact");
            return nil;
        }
        if (code.length != [n[@"bytes"] unsignedIntValue] ||
            (((const uint8_t*)code.bytes)[0]&15)!=[n[@"first_tag"] unsignedIntValue] ||
            reflect.length != [f[@"bytes"] unsignedIntValue] || ![digest(code) isEqual:n[@"sha256"]] ||
            ![digest(reflect) isEqual:f[@"sha256"]])
            return fail(error, EINVAL, @"dynamic stage native/reflection integrity rejected");
        id reflection = [NSJSONSerialization JSONObjectWithData:reflect options:0 error:NULL];
        if (![reflection isKindOfClass:NSDictionary.class])
            return fail(error, EINVAL, @"dynamic stage reflection is not a dictionary");
        A5MaliDynamicShaderCacheEntry *entry =
            [[A5MaliDynamicShaderCacheEntry alloc] initWithRequest:requestID
                                                           payload:functionPayload
                                                           receipt:r
                                                              code:code
                                                        reflection:reflection];
        if (![entry deriveABI])
            return fail(error, ENOTSUP, @"published stage needs an unsupported or malformed reflected ABI");
        return entry;
    } @catch (NSException *exception) {
        (void)exception;
        return fail(error, EINVAL, @"malformed dynamic stage metadata");
    }
}
