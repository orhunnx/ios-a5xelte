/* SPDX-License-Identifier: MIT
 * Synthetic root publication/parser tests; no translated shader/GPU execution.
 */
#import "A5MaliDynamicShaderCache.h"
#import <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
static uid_t testUID;
uid_t A5MaliDynamicShaderCacheTestUID(void) { return testUID; }
static NSString *sha(NSData *d) {
    unsigned char b[32];
    CC_SHA256(d.bytes, (CC_LONG)d.length, b);
    char s[65];
    for (unsigned i = 0; i < 32; i++)
        snprintf(s + i * 2, 3, "%02x", b[i]);
    return [NSString stringWithUTF8String:s];
}
static NSData *j(id o) {
    return [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:NULL];
}
static id clone(id o) {
    return [NSJSONSerialization JSONObjectWithData:j(o) options:NSJSONReadingMutableContainers error:NULL];
}
static void writeFile(NSString *p, NSData *d) {
    chmod(p.fileSystemRepresentation, 0600);
    assert([d writeToFile:p atomically:NO]);
    assert(!chmod(p.fileSystemRepresentation, 0444));
}
static NSDictionary *reflection(void) {
    return @{
        @"layout" : @{
            @"sets" : @[ @{
                @"set" : @0,
                @"bindings" : @[
                    @{
                        @"binding" : @2,
                        @"ty" : @6,
                        @"count" : @1,
                        @"stages" : @16,
                        @"source" :
                            @{@"Buffer" : @{@"stage" : @"Fragment", @"class" : @"Buffer", @"index" : @1}},
                        @"immutable_sampler" : NSNull.null,
                        @"flags" : @0
                    },
                    @{
                        @"binding" : @5,
                        @"ty" : @1,
                        @"count" : @1,
                        @"stages" : @16,
                        @"source" : @{
                            @"CombinedTextureSampler" : @{
                                @"texture" : @{@"stage" : @"Fragment", @"class" : @"Texture", @"index" : @3},
                                @"sampler" : @{
                                    @"sampler" : @{@"Slot" : @0},
                                    @"compare" : @NO,
                                    @"integer" : @NO,
                                    @"cube_gradient" : @NO,
                                    @"raw" : @NO
                                }
                            }
                        },
                        @"immutable_sampler" : NSNull.null,
                        @"flags" : @0
                    }
                ]
            } ]
        },
        @"interface" : @{
            @"slots" : @[ @[
                @{@"stage" : @"Fragment",
                  @"class" : @"Buffer",
                  @"index" : @1},
                @{
                    @"Buffer" : @{
                        @"access" : @{@"read" : @YES, @"write" : @NO},
                        @"window" : @{@"Bounded" : @{@"start" : @0, @"len" : @168}},
                        @"form" : @{@"Descriptor" : @"UniformWords"}
                    }
                }
            ] ],
            @"push" : @[ @{
                @"stage" : @"Fragment",
                @"fields" : @[
                    @{
                        @"field" : @{
                            @"SlotBindOffset" : @{@"stage" : @"Fragment", @"class" : @"Buffer", @"index" : @1}
                        },
                        @"loc" : @{@"Push" : @{@"offset" : @64}},
                        @"size" : @4
                    },
                    @{
                        @"field" : @{@"ColorWriteRule" : @0},
                        @"loc" : @{@"Push" : @{@"offset" : @72}},
                        @"size" : @4
                    }
                ]
            } ]
        },
        @"graphics" : @{@"color_write_rules" : @[ @[ @0, @8738 ] ]},
        @"vertex_input" : @{}
    };
}
static NSDictionary *abi(void) {
    return @{
        @"schema" : @1,
        @"stage" : @"fragment",
        @"native_info" : @{
            @"bytes" : @16,
            @"first_tag" : @5,
            @"work_regs" : @2,
            @"tls" : @0,
            @"wls" : @0,
            @"attributes" : @0,
            @"ubos" : @4,
            @"textures" : @1,
            @"samplers" : @1
        },
        @"live_ubos" :
            @[ @{@"native_index" : @0,
                 @"min_bytes" : @76},
               @{@"native_index" : @3,
                 @"min_bytes" : @128} ],
        @"live_textures" : @[ @0 ],
        @"sysval_ubo0_read_extent" : @76,
        @"inputs" : @[
            @{@"location" : @32,
              @"base" : @0,
              @"component" : @0,
              @"components" : @2,
              @"bit_size" : @32}
        ],
        @"outputs" : @[
            @{@"location" : @4,
              @"base" : @0,
              @"component" : @0,
              @"components" : @4,
              @"bit_size" : @32}
        ]
    };
}
int main(void) {
    @autoreleasepool {
        testUID = geteuid();
        NSString *root = @A5_DYNAMIC_SHADER_CACHE_TEST_ROOT;
        assert([root hasPrefix:@"/private/tmp/"]);
        [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:root
                                         withIntermediateDirectories:NO
                                                          attributes:nil
                                                               error:NULL]);
        assert(!chmod(root.fileSystemRepresentation, 0755));
        NSDictionary *p = @{
            @"schema" : @1,
            @"kind" : @"function",
            @"source_library" : @"quartzcore",
            @"metallib_sha256" : @"11c74cc42ce5137b73d44d427f75764f886656d4ddb374422d56b609ed2762d9",
            @"gpu_id" : @"07201000",
            @"compiler_abi" : @1,
            @"stage" : @"fragment",
            @"function" : @"unreviewed_fragment",
            @"named_constants" : @[
                @{@"name" : @"new_feature",
                  @"type" : @53,
                  @"bytes" : @1,
                  @"raw" : @"01"}
            ],
            @"indexed_constants" : @[]
        };
        NSMutableDictionary *body = [p mutableCopy];
        body[@"owner_uid"] = @(geteuid());
        NSString *rid = sha(j(body));
        NSString *dir = [root stringByAppendingPathComponent:rid];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:dir
                                         withIntermediateDirectories:NO
                                                          attributes:nil
                                                               error:NULL]);
        assert(!chmod(dir.fileSystemRepresentation, 0755));
        uint8_t raw[16] = {5, 1, 2, 3};
        NSData *code = [NSData dataWithBytes:raw length:16];
        NSData *reflect = j(reflection());
        NSDictionary *base = @{
            @"schema" : @2,
            @"kind" : @"dynamic-stage",
            @"request_id" : rid,
            @"source_library" : @"quartzcore",
            @"metallib_sha256" : p[@"metallib_sha256"],
            @"gpu_id" : @"07201000",
            @"compiler_abi" : @1,
            @"stage" : @"fragment",
            @"function" : @"unreviewed_fragment",
            @"named_constants_sha256" : sha(j(p[@"named_constants"])),
            @"indexed_constants_sha256" : sha(j(p[@"indexed_constants"])),
            @"stage_compiled" : @YES,
            @"pipeline_compatible" : @NO,
            @"native" : @{
                @"file" : @"stage.midgard",
                @"bytes" : @16,
                @"sha256" : sha(code),
                @"first_tag" : @5,
                @"work_registers" : @2,
                @"tls_bytes" : @0,
                @"wls_bytes" : @0
            },
            @"reflection" :
                @{@"file" : @"reflection.json", @"bytes" : @(reflect.length), @"sha256" : sha(reflect)},
            @"native_abi" : abi()
        };
        NSString *receipt = [dir stringByAppendingPathComponent:@"receipt.json"],
                 *native = [dir stringByAppendingPathComponent:@"stage.midgard"],
                 *meta = [dir stringByAppendingPathComponent:@"reflection.json"];
        writeFile(native, code);
        writeFile(meta, reflect);
        writeFile(receipt, j(base));
        NSError *error = nil;
        A5MaliDynamicShaderCacheEntry *entry = A5MaliLoadDynamicShaderStage(rid, p, &error);
        if (!entry)
            NSLog(@"%@", error);
        assert(entry && !error && entry.stage == 2 && entry.resourceCount == 3 && entry.pushFieldCount == 2 &&
               entry.shader->byteCount == 16);
        assert(!memcmp(entry.shader->bytes, raw, 16));
        assert(entry.resources[0].nativeIndex == 3 && entry.resources[0].uniformBytes == 128 &&
               entry.resources[0].pushOffset == 64);
        assert(entry.resources[1].kind == 2 && entry.resources[1].metalIndex == 3 &&
               entry.resources[2].kind == 3);
        NSMutableDictionary *lanes = clone(base);
        [lanes[@"native_abi"][@"inputs"] addObject:@{
            @"location" : @32,
            @"base" : @0,
            @"component" : @0,
            @"components" : @1,
            @"bit_size" : @32
        }];
        writeFile(receipt, j(lanes));
        assert(A5MaliLoadDynamicShaderStage(rid, p, &error));
        lanes[@"native_abi"][@"inputs"][1] = [lanes[@"native_abi"][@"inputs"][1] mutableCopy];
        lanes[@"native_abi"][@"inputs"][1][@"base"] = @1;
        writeFile(receipt, j(lanes));
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        /* Ordered color0 fetch must agree in compiler liveness and reflected
         * renderpass metadata. It is never exposed as a sampled texture. */
        NSMutableDictionary *fetchReflection=clone(reflection());
        [fetchReflection[@"layout"][@"sets"][0][@"bindings"] addObject:@{
            @"binding":@6,@"ty":@10,@"count":@1,@"stages":@16,@"flags":@0,
            @"source":@{@"InputAttachment":@0},@"immutable_sampler":NSNull.null}];
        fetchReflection[@"graphics"][@"rasterization_order_attachment_access"]=@YES;
        fetchReflection[@"graphics"][@"rasterization_samples"]=@1;
        fetchReflection[@"graphics"][@"input_attachments"]=
            @[@{@"color_index":@0,@"input_attachment_index":@0,@"format_class":@"Float"}];
        for(unsigned fault=0;fault<7;fault++){
            NSMutableDictionary *fr=clone(fetchReflection),*r=clone(base);
            r[@"native_abi"][@"framebuffer_fetch"]=@YES;
            if(fault==1)r[@"native_abi"][@"framebuffer_fetch"]=@NO;
            if(fault==2)fr[@"graphics"][@"rasterization_order_attachment_access"]=@NO;
            if(fault==3)fr[@"graphics"][@"rasterization_samples"]=@4;
            if(fault==4)fr[@"layout"][@"sets"][0][@"bindings"][2][@"source"][@"InputAttachment"]=@1;
            if(fault==5)fr[@"graphics"][@"input_attachments"]=@[];
            if(fault==6)r[@"native_abi"][@"framebuffer_fetch"]=@1;
            NSData *data=j(fr);writeFile(meta,data);
            r[@"reflection"]=@{@"file":@"reflection.json",@"bytes":@(data.length),@"sha256":sha(data)};
            writeFile(receipt,j(r));
            A5MaliDynamicShaderCacheEntry *got=A5MaliLoadDynamicShaderStage(rid,p,&error);
            if(!fault)assert(got&&got.resourceCount==4&&got.resources[3].kind==A5MaliResourceInputAttachment);
            else assert(!got&&error.code!=ENOENT);
        }
        writeFile(meta,reflect);
        for (unsigned fault = 0; fault < 15; fault++) {
            NSMutableDictionary *r = clone(base);
            switch (fault) {
            case 0:
                r[@"metallib_sha256"] = rid;
                break;
            case 1:
                r[@"named_constants_sha256"] = rid;
                break;
            case 2:
                r[@"request_id"] = sha(code);
                break;
            case 3:
                r[@"native"][@"bytes"] = @16.5;
                break;
            case 4:
                r[@"native"][@"sha256"] = rid;
                break;
            case 5:
                r[@"native"][@"file"] = @"../stage.midgard";
                break;
            case 6:
                r[@"native_abi"][@"live_ubos"][1][@"min_bytes"] = @169;
                break;
            case 7:
                r[@"native_abi"][@"live_ubos"][1][@"native_index"] = @6;
                break;
            case 8:
                r[@"native_abi"][@"inputs"][0][@"components"] = @5;
                break;
            case 9:
                r[@"native_abi"][@"sysval_ubo0_read_extent"] = @577;
                break;
            case 10:
                r[@"native_abi"][@"live_textures"] = @[ @1 ];
                break;
            case 11:
                r[@"stage_compiled"] = @NO;
                r[@"error"] = @"unsupported real ABI";
                break;
            case 12:
                r[@"native"][@"work_registers"] = @0;
                break;
            case 13:
                r[@"pipeline_compatible"] = @YES;
                break;
            case 14:
                r[@"reflection"][@"bytes"] = @262145;
                break;
            }
            writeFile(receipt, j(r));
            id bad = A5MaliLoadDynamicShaderStage(rid, p, &error);
            if (bad || error.code == ENOENT)
                fprintf(stderr, "unexpected acceptance fault=%u error=%s\n", fault,
                        error.description.UTF8String);
            assert(!bad && error.code != ENOENT);
        }
        writeFile(receipt, j(base));
        assert(!chmod(native.fileSystemRepresentation, 0644));
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        assert(!chmod(native.fileSystemRepresentation, 0444));
        testUID = geteuid() + 1;
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        testUID = geteuid();
        NSString *other = [root stringByAppendingPathComponent:@"alias"];
        assert(!link(native.fileSystemRepresentation, other.fileSystemRepresentation));
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        assert(!unlink(other.fileSystemRepresentation));
        assert(!unlink(native.fileSystemRepresentation));
        assert(!symlink(meta.fileSystemRepresentation, native.fileSystemRepresentation));
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        assert(!unlink(native.fileSystemRepresentation));
        writeFile(native, code);
        NSMutableDictionary *changed = clone(p);
        changed[@"named_constants"][0][@"raw"] = @"00";
        assert(!A5MaliLoadDynamicShaderStage(rid, changed, &error));
        assert(!chmod(dir.fileSystemRepresentation, 0777));
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error));
        assert(!chmod(dir.fileSystemRepresentation, 0755));
        /* Compiler generation participates in identity. A copied generation1
         * receipt cannot impersonate a shader-lowered anisotropic fragment. */
        NSMutableDictionary *p2=clone(p);p2[@"compiler_abi"]=@2;
        NSMutableDictionary *body2=[p2 mutableCopy];body2[@"owner_uid"]=@(geteuid());
        NSString *rid2=sha(j(body2));assert(![rid2 isEqual:rid]);
        NSString *dir2=[root stringByAppendingPathComponent:rid2];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:dir2 withIntermediateDirectories:NO attributes:nil error:NULL]);
        assert(!chmod(dir2.fileSystemRepresentation,0755));
        NSString *receipt2=[dir2 stringByAppendingPathComponent:@"receipt.json"];
        writeFile([dir2 stringByAppendingPathComponent:@"stage.midgard"],code);
        writeFile([dir2 stringByAppendingPathComponent:@"reflection.json"],reflect);
        NSMutableDictionary *r2=clone(base);r2[@"request_id"]=rid2;
        writeFile(receipt2,j(r2));assert(!A5MaliLoadDynamicShaderStage(rid2,p2,&error));
        r2[@"compiler_abi"]=@2;
        writeFile(receipt2,j(r2));assert(!A5MaliLoadDynamicShaderStage(rid2,p2,&error));
        r2[@"native_abi"][@"shader_anisotropy"]=@1;
        writeFile(receipt2,j(r2));id gen2=A5MaliLoadDynamicShaderStage(rid2,p2,&error);if(!gen2)NSLog(@"generation2: %@",error);assert(gen2);
        r2[@"native_abi"][@"shader_anisotropy"]=@0;
        writeFile(receipt2,j(r2));assert(!A5MaliLoadDynamicShaderStage(rid2,p2,&error));
        /* The retained entry survives replacing/removing publication and all caller dictionaries. */
        [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        assert(!memcmp(entry.shader->bytes, raw, 16) && entry.resources[0].uniformBytes == 128 &&
               entry.functionName.length && entry.shader->sha256[0]);
        assert(!A5MaliLoadDynamicShaderStage(rid, p, &error) && error.code == ENOENT);
        puts("dynamic stage cache: unknown function/code accepted by root provenance+reflected ABI; typed "
             "identity, resource/push mapping, lifetime, "
             "corruption/bounds/ownership/modes/symlink/hardlink/failure cases PASS (no GPU execution)");
    }
    return 0;
}
