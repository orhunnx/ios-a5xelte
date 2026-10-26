/* SPDX-License-Identifier: MIT
 * Bounded root worker for exact, typed Metal requests forwarded by the
 * provider. Included by a5shader_compile.m after its process-limit helpers.
 * No provider-supplied path, command, shader bytes or GPU address is executed.
 */
#include <dirent.h>
#include "../../a5mali-metal/A5MaliShaderSpool.h"

#ifndef A5_SHADER_HOST_TEST
static NSString *const requestRoot = @"/private/var/tmp/a5mali-shader-requests";
static NSString *const publishedRoot = @"/private/var/tmp/a5mali-shader-compiled";
#else
#ifndef A5_TEST_REQUESTS
#define A5_TEST_REQUESTS "/private/tmp/a5shader-host-unused-requests"
#endif
#ifndef A5_TEST_PUBLISHED
#define A5_TEST_PUBLISHED "/private/tmp/a5shader-host-unused-published"
#endif
static NSString *const requestRoot = @A5_TEST_REQUESTS;
static NSString *const publishedRoot = @A5_TEST_PUBLISHED;
#endif

static void a5PrepareRequestRoots(void)
{
    for (NSString *path in @[requestRoot,publishedRoot]) {
        mode_t mode = [path isEqual:requestRoot] ? 01777 : 0755;
        struct stat st;
        if (lstat(path.fileSystemRepresentation,&st)) {
            if (errno != ENOENT ||
                ![NSFileManager.defaultManager createDirectoryAtPath:path
                    withIntermediateDirectories:NO
                    attributes:@{NSFilePosixPermissions:@(mode)} error:NULL] ||
                chmod(path.fileSystemRepresentation,mode))
                fail(@"cannot create shader request/publication root");
        }
        if (lstat(path.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) ||
            st.st_uid != geteuid() || (st.st_mode & 07777) != mode)
            fail(@"untrusted shader request/publication root");
    }
}

static BOOL a5HexDigest(NSString *s)
{
    if (![s isKindOfClass:NSString.class] || s.length != 64) return NO;
    for (NSUInteger i = 0; i < 64; ++i) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static NSData *a5Canonical(id value)
{
    return [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingSortedKeys error:NULL];
}

static BOOL a5ExactKeys(NSDictionary *d, NSArray<NSString *> *keys)
{
    return [d isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:d.allKeys] isEqual:[NSSet setWithArray:keys]];
}

static BOOL a5RequestFunction(NSDictionary *f, NSString *stage,
                              NSString *name, NSArray *constants,
                              NSString *sourceSHA)
{
    if (!a5ExactKeys(f,@[@"schema",@"kind",@"source_library",@"metallib_sha256",
                         @"gpu_id",@"compiler_abi",@"stage",@"function",
                         @"named_constants",@"indexed_constants"])) return NO;
    return [f[@"schema"] isEqual:@1] && [f[@"kind"] isEqual:@"function"] &&
        [f[@"source_library"] isEqual:@"quartzcore"] &&
        [f[@"metallib_sha256"] isEqual:sourceSHA] &&
        [f[@"gpu_id"] isEqual:@"07201000"] &&
        ([f[@"compiler_abi"] isEqual:@1]||([stage isEqual:@"fragment"]&&[f[@"compiler_abi"] isEqual:@2])) && [f[@"stage"] isEqual:stage] &&
        [f[@"function"] isEqual:name] &&
        [f[@"named_constants"] isEqual:constants] &&
        [f[@"indexed_constants"] isEqual:@[]];
}

static BOOL a5KnownProfile(NSDictionary *request, NSDictionary *known)
{
    if (![request[@"kind"] isEqual:@"pipeline"] ||
        !a5ExactKeys(request,@[@"schema",@"kind",@"source_library",
            @"metallib_sha256",@"gpu_id",@"compiler_abi",@"vertex",
            @"fragment",@"descriptor",@"owner_uid",@"request_id"])) return NO;
    return [request[@"schema"] isEqual:@1] &&
        [request[@"source_library"] isEqual:@"quartzcore"] &&
        [request[@"metallib_sha256"] isEqual:known[@"metallib_sha256"]] &&
        [request[@"gpu_id"] isEqual:@"07201000"] &&
        [request[@"compiler_abi"] isEqual:@1] &&
        [request[@"descriptor"] isKindOfClass:NSDictionary.class] &&
        a5RequestFunction(request[@"vertex"],@"vertex",known[@"vertex_function"],
                          known[@"vertex_constants"],known[@"metallib_sha256"]) &&
        a5RequestFunction(request[@"fragment"],@"fragment",known[@"fragment_function"],
                          known[@"fragment_constants"],known[@"metallib_sha256"]);
}

static NSData *a5ReadRequest(int directory, const char *name, uid_t uid)
{
    int fd = openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    BOOL ok = !fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_uid == uid &&
        st.st_nlink == 1 && (st.st_mode & 0777) == 0600 &&
        st.st_size > 0 && st.st_size <= 128*1024;
    NSMutableData *data = ok ? [NSMutableData dataWithLength:(NSUInteger)st.st_size] : nil;
    uint8_t *p = data.mutableBytes;
    NSUInteger left = data.length;
    while (ok && left) {
        ssize_t n = read(fd,p,left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        p += n; left -= (NSUInteger)n;
    }
    uint8_t extra;
    if (ok && read(fd,&extra,1) != 0) ok = NO;
    close(fd);
    return ok ? data : nil;
}

static void a5WriteStatus(NSString *key, NSString *status, NSString *reason)
{
    NSString *folder = [cacheRoot stringByAppendingPathComponent:@"request-status"];
    /* mkdir is idempotent here. Foundation's createDirectoryAtPath returns NO
     * for an existing directory on the device, which used to terminate the
     * worker after its first unsupported request. A pre-existing object must
     * still be checked, including owner, type and exact private mode. */
    if (mkdir(folder.fileSystemRepresentation,0700) && errno != EEXIST) {
        fprintf(stderr,"A5XELTE shader compiler: cannot create status directory errno=%d\n",errno);
        _exit(1); /* fail() itself attempts to record a request status */
    }
    int directory = open(folder.fileSystemRepresentation,
                         O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if (directory < 0 || fstat(directory,&st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid() || (st.st_mode & 07777) != 0700) {
        fprintf(stderr,"A5XELTE shader compiler: untrusted request status directory\n");
        if (directory >= 0) close(directory);
        _exit(1);
    }
    NSData *data = a5Canonical(@{@"schema":@1,@"request_id":key,
        @"status":status,@"reason":reason});
    if (!data || !a5HexDigest(key)) {
        fprintf(stderr,"A5XELTE shader compiler: invalid request status\n");
        close(directory); _exit(1);
    }
    NSString *name = [key stringByAppendingString:@".json"];
    int fd = openat(directory,name.fileSystemRepresentation,
                    O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd < 0 && errno == EEXIST) {
        fd = openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        BOOL trusted = fd >= 0 && !fstat(fd,&st) && S_ISREG(st.st_mode) &&
            st.st_uid == geteuid() && st.st_nlink == 1 &&
            (st.st_mode & 07777) == 0600;
        if (fd >= 0) close(fd);
        close(directory);
        if (trusted) return;
        fprintf(stderr,"A5XELTE shader compiler: untrusted existing request status\n");
        _exit(1);
    }
    if (fd < 0) {
        fprintf(stderr,"A5XELTE shader compiler: cannot create request status errno=%d\n",errno);
        close(directory); _exit(1);
    }
    const uint8_t *p = data.bytes;
    NSUInteger left = data.length;
    while (left) {
        ssize_t n = write(fd,p,left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            fprintf(stderr,"A5XELTE shader compiler: short request status write\n");
            close(fd); close(directory); _exit(1);
        }
        p += n; left -= (NSUInteger)n;
    }
    if (fsync(fd) || close(fd) || fsync(directory) || close(directory)) {
        fprintf(stderr,"A5XELTE shader compiler: request status sync failed\n");
        _exit(1);
    }
}

static NSArray<NSString *> *a5ConstantArguments(NSArray<NSDictionary *> *constants)
{
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSDictionary *item in constants) {
        NSNumber *type = item[@"type"];
        NSString *kind = [type isEqual:@49] ? @"uchar" :
                         [type isEqual:@51] ? @"uchar3" :
                         [type isEqual:@53] ? @"bool" : nil;
        NSString *raw = item[@"raw"];
        NSUInteger width = [type isEqual:@51] ? 3 : 1;
        if (!kind || ![raw isKindOfClass:NSString.class] || raw.length != 2*width ||
            ![item[@"bytes"] isEqual:@(width)]) fail(@"generic constant width/type differs");
        NSMutableArray *values = [NSMutableArray array];
        for (NSUInteger i=0; i<width; ++i) {
            unsigned n=0;
            if (![[NSScanner scannerWithString:[raw substringWithRange:NSMakeRange(2*i,2)]] scanHexInt:&n])
                fail(@"invalid generic constant hex");
            [values addObject:[type isEqual:@53] ? (n ? @"true" : @"false") :
                [NSString stringWithFormat:@"%u",n]];
        }
        [args addObjectsFromArray:@[@"--constant",[NSString stringWithFormat:@"%@:%@:%@",
            item[@"name"],kind,[values componentsJoinedByString:@","]]]];
    }
    return args;
}

static void a5PinnedFile(NSString *path, NSDictionary *pin)
{
    NSData *data = regularData(path,1024*1024);
    if (![@(data.length) isEqual:pin[@"bytes"]] ||
        ![digest(data) isEqual:pin[@"sha256"]])
        fail([@"exact generic compiler output differs: " stringByAppendingString:path]);
}

static NSDictionary *a5NativeRecord(NSString *filename, NSDictionary *pin,
                                    NSUInteger registers)
{
    return @{@"file":filename,@"bytes":pin[@"bytes"],@"sha256":pin[@"sha256"],
             @"first_tag":@5,@"work_registers":@(registers),
             @"tls_bytes":@0,@"wls_bytes":@0};
}

static void a5CompileKnown(NSString *self, NSDictionary *request, NSDictionary *known)
{
    NSString *key = request[@"request_id"];
    NSString *final = [publishedRoot stringByAppendingPathComponent:key];
    if ([NSFileManager.defaultManager fileExistsAtPath:final]) {
        fprintf(stderr,"A5XELTE shader compiler: compiled request already published %s\n",key.UTF8String);
        return;
    }
    activeRequestKey = key;
    NSString *work = [cacheRoot stringByAppendingPathComponent:
        [@".request-work-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:work
        withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL])
        fail(@"cannot create generic compiler workspace");
    activeWork = work;
    NSString *prefix = [work stringByAppendingPathComponent:@"shader"];
    NSString *meta = [work stringByAppendingPathComponent:@"reflection.json"];
    NSString *packing = [work stringByAppendingPathComponent:@"packing0.json"];
    NSData *packingData = a5Canonical(known[@"configured_vertex_packing0"]);
    if (!packingData) fail(@"cannot serialize known vertex packing");
    writeData(packingData,packing);
    NSMutableArray *air = [NSMutableArray arrayWithArray:@[
        [installed stringByAppendingPathComponent:@"metal2vulkan"],sourceLibrary,
        [prefix stringByAppendingString:@".spv"],@"--profile",
        [installed stringByAppendingPathComponent:@"profile.json"],
        @"--function",known[@"vertex_function"],@"--fragment",known[@"fragment_function"],
        @"--color-format",@"0:BGRA8Unorm",@"--vertex-descriptor",packing,
        @"--emit-meta",meta,@"--no-timeout"]];
    [air addObjectsFromArray:a5ConstantArguments(known[@"fragment_constants"])];
    setenv("METAL2VULKAN_SPIRV_VAL",
        [installed stringByAppendingPathComponent:@"spirv-val"].fileSystemRepresentation,1);
    run(self,air,[work stringByAppendingPathComponent:@"air.log"]);
    NSString *airText = [[NSString alloc] initWithData:regularData(
        [work stringByAppendingPathComponent:@"air.log"],8*1024*1024)
        encoding:NSUTF8StringEncoding];
    if (![airText containsString:@"spirv-val vulkan1.2: PASS"])
        fail(@"generic SPIR-V validation did not run");
    NSDictionary *reflection = readJSON(meta);
    if (![reflection[@"vertex_input"] isEqual:known[@"reflected_vertex_input"]] ||
        ![reflection[@"layout"] isEqual:known[@"reflected_layout"]] ||
        ![reflection[@"graphics"][@"color_write_rules"] isEqual:
            known[@"reflected_color_write_rules"]])
        fail(@"generic translated metadata differs");
    for (NSString *stage in @[@"vert",@"frag"]) {
        NSString *spv = [prefix stringByAppendingFormat:@".%@.spv",stage];
        a5PinnedFile(spv,known[@"spirv"][stage]);
    }
    run(self,@[[installed stringByAppendingPathComponent:@"midgard-generic602"],
        [prefix stringByAppendingString:@".vert.spv"],
        [prefix stringByAppendingString:@".frag.spv"],
        [prefix stringByAppendingString:@".vert.midgard"],
        [prefix stringByAppendingString:@".frag.midgard"]],
        [work stringByAppendingPathComponent:@"midgard.log"]);
    for (NSString *stage in @[@"vert",@"frag"])
        a5PinnedFile([prefix stringByAppendingFormat:@".%@.midgard",stage],
                     known[@"midgard"][stage]);
    NSString *pubWork = [publishedRoot stringByAppendingPathComponent:
        [@".work-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:pubWork
        withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL])
        fail(@"cannot create publication workspace");
    for (NSString *stage in @[@"vert",@"frag"]) {
        NSString *name = [stage isEqual:@"vert"] ? @"vertex.midgard" : @"fragment.midgard";
        NSString *src = [prefix stringByAppendingFormat:@".%@.midgard",stage];
        NSString *dst = [pubWork stringByAppendingPathComponent:name];
        writeData(regularData(src,1024*1024),dst);
        if (chmod(dst.fileSystemRepresentation,0444)) fail(@"cannot mark compiled shader readonly");
    }
    NSData *descriptorData = a5Canonical(request[@"descriptor"]);
    NSData *vertexData = a5Canonical(request[@"vertex"][@"named_constants"]);
    NSData *fragmentData = a5Canonical(request[@"fragment"][@"named_constants"]);
    if (!descriptorData || !vertexData || !fragmentData) fail(@"invalid request contract serialization");
    NSNumber *profile = known[@"profile_id"];
    NSString *recipeName = [NSString stringWithFormat:@"quartzcore-generic-%@",profile];
    NSDictionary *receipt = @{@"schema":@1,@"request_id":key,@"profile_id":profile,
        @"source_library":@"quartzcore",@"metallib_sha256":known[@"metallib_sha256"],
        @"gpu_id":@"07201000",@"compiler_abi":@1,
        @"recipe":recipeName,@"stage_compiled":@YES,
        @"pipeline_compatible":@NO,
        @"descriptor_sha256":digest(descriptorData),
        @"vertex_constants_sha256":digest(vertexData),
        @"fragment_constants_sha256":digest(fragmentData),
        @"vertex":a5NativeRecord(@"vertex.midgard",known[@"midgard"][@"vert"],
            [known[@"midgard"][@"vert"][@"native_info"][@"work_regs"] unsignedIntegerValue]),
        @"fragment":a5NativeRecord(@"fragment.midgard",known[@"midgard"][@"frag"],
            [known[@"midgard"][@"frag"][@"native_info"][@"work_regs"] unsignedIntegerValue])};
    NSString *receiptPath = [pubWork stringByAppendingPathComponent:@"receipt.json"];
    writeData(a5Canonical(receipt),receiptPath);
    if (chmod(receiptPath.fileSystemRepresentation,0444) ||
        chmod(pubWork.fileSystemRepresentation,0755))
        fail(@"cannot mark compiled receipt readonly");
    for (NSString *name in @[@"receipt.json",@"vertex.midgard",@"fragment.midgard"]) {
        int fd = open([pubWork stringByAppendingPathComponent:name].fileSystemRepresentation,
                      O_RDONLY|O_NOFOLLOW);
        if (fd<0 || fsync(fd) || close(fd)) fail(@"compiled publication sync failed");
    }
    int directory = open(pubWork.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (directory<0 || fsync(directory) || close(directory) ||
        rename(pubWork.fileSystemRepresentation,final.fileSystemRepresentation))
        fail(@"compiled publication rename failed");
    directory = open(publishedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if (directory<0 || fsync(directory) || close(directory)) fail(@"compiled publication sync failed");
    [NSFileManager.defaultManager removeItemAtPath:work error:NULL];
    activeWork = nil;
    activeRequestKey = nil;
    fprintf(stderr,"A5XELTE shader compiler: PUBLISHED profile=%u request=%s\n",
        profile.unsignedIntValue,key.UTF8String);
}

static NSData *a5ReadPublishedFile(int directory, const char *name, size_t limit)
{
    int fd = openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if (fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) ||
        st.st_uid!=geteuid() || st.st_nlink!=1 ||
        (st.st_mode&07777)!=0444 || st.st_size<=0 ||
        (uint64_t)st.st_size>limit) fail(@"untrusted compiled shader publication file");
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *p=data.mutableBytes;size_t left=data.length;
    while(left){ssize_t n=read(fd,p,left);if(n<0&&errno==EINTR)continue;
        if(n<=0)fail(@"short compiled shader publication read");
        p+=n;left-=(size_t)n;}
    uint8_t extra;if(read(fd,&extra,1)!=0||close(fd))
        fail(@"compiled shader publication size changed");
    return data;
}

/* Request IDs hash the actual Metal call, not the compiler recipe. After an
 * upgrade the same request may have an old, root-owned 603 result. Remove
 * only the exact published pixel-coordinate shader from the previous recipe;
 * an unknown or untrusted entry is never silently replaced. */
static BOOL a5PublishedCurrentOrRetire603(NSString *key, NSDictionary *known)
{
    int root=open(publishedRoot.fileSystemRepresentation,
                  O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if(root<0||fstat(root,&st)||!S_ISDIR(st.st_mode)||
       st.st_uid!=geteuid()||(st.st_mode&07777)!=0755)
        fail(@"untrusted compiled shader publication root");
    int dir=openat(root,key.fileSystemRepresentation,
                   O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(dir<0){if(errno!=ENOENT)fail(@"untrusted compiled shader publication entry");
        close(root);return NO;}
    if(fstat(dir,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||
       (st.st_mode&07777)!=0755)fail(@"untrusted compiled shader publication directory");
    DIR *names=fdopendir(dup(dir));if(!names)fail(@"cannot enumerate compiled publication");
    unsigned files=0;struct dirent *entry;
    while((entry=readdir(names))){if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(strcmp(entry->d_name,"receipt.json")&&strcmp(entry->d_name,"vertex.midgard")&&
           strcmp(entry->d_name,"fragment.midgard"))fail(@"unexpected compiled publication file");
        ++files;}
    closedir(names);if(files!=3)fail(@"incomplete compiled publication");
    NSData *record=a5ReadPublishedFile(dir,"receipt.json",16384);
    NSDictionary *receipt=[NSJSONSerialization JSONObjectWithData:record options:0 error:NULL];
    NSData *vertex=a5ReadPublishedFile(dir,"vertex.midgard",1024*1024);
    NSData *fragment=a5ReadPublishedFile(dir,"fragment.midgard",1024*1024);
    NSString *vertexSHA=known[@"midgard"][@"vert"][@"sha256"];
    NSString *fragmentSHA=known[@"midgard"][@"frag"][@"sha256"];
    if(![receipt isKindOfClass:NSDictionary.class]||
       ![receipt[@"request_id"] isEqual:key]||
       ![receipt[@"profile_id"] isEqual:@603]||
       ![receipt[@"source_library"] isEqual:@"quartzcore"]||
       ![receipt[@"metallib_sha256"] isEqual:known[@"metallib_sha256"]]||
       ![receipt[@"gpu_id"] isEqual:@"07201000"]||
       ![receipt[@"compiler_abi"] isEqual:@1]||
       ![receipt[@"recipe"] isEqual:@"quartzcore-generic-603"]||
       ![receipt[@"vertex"][@"sha256"] isEqual:vertexSHA]||
       ![digest(vertex) isEqual:vertexSHA]||vertex.length!=2192||
       ![receipt[@"vertex"][@"bytes"] isEqual:@2192])
        fail(@"untrusted compiled 603 publication identity");
    NSString *actual=digest(fragment);
    if(![receipt[@"fragment"][@"sha256"] isEqual:actual]||
       ![receipt[@"fragment"][@"bytes"] isEqual:@(fragment.length)])
        fail(@"compiled 603 fragment receipt differs from bytes");
    if([actual isEqual:fragmentSHA]&&
       [receipt[@"fragment"][@"work_registers"] isEqual:@5]&&fragment.length==880){
        close(dir);close(root);return YES;
    }
    if(![actual isEqual:@"b7ab26bc9a0da3ff4a5f87e73fe6aaab07680ae383a3fbdd9d8abc000387cd96"]||
       fragment.length!=976||![receipt[@"fragment"][@"work_registers"] isEqual:@6])
        fail(@"unknown stale compiled 603 shader; refusing replacement");
    /* Move the authenticated old publication out of the request-ID name in
     * one filesystem operation. A crash here leaves a complete old directory
     * under a private retired name; the next scan can compile the request. */
    NSString *retired=[@".retired603-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if(renameat(root,key.fileSystemRepresentation,root,retired.fileSystemRepresentation)||
       fsync(root))fail(@"cannot atomically retire stale compiled shader");
    fprintf(stderr,"A5XELTE shader compiler: retired old pixel-UV 603 request=%s\n",key.UTF8String);
#ifdef A5_SHADER_HOST_TEST
    if(getenv("A5_TEST_STOP_AFTER_RENAME603"))_exit(57);
#endif
    BOOL cleaned=YES;
    for(const char *name[] = {"receipt.json","vertex.midgard","fragment.midgard"}, **p=name;
        p<name+3;++p)if(unlinkat(dir,*p,0))cleaned=NO;
    if(fsync(dir))cleaned=NO;
    if(close(dir))cleaned=NO;
    if(cleaned&&unlinkat(root,retired.fileSystemRepresentation,AT_REMOVEDIR))cleaned=NO;
    if(fsync(root))cleaned=NO;
    if(close(root))cleaned=NO;
    if(!cleaned)fprintf(stderr,"A5XELTE shader compiler: retired 603 cleanup deferred request=%s\n",key.UTF8String);
    return NO;
}

/* Dynamic stage compilation is independent of the reviewed executable
 * pipeline recipes. It publishes native code and reflection, never a blanket
 * claim that an arbitrary pipeline can execute. */
static BOOL a5Unsigned(id value,uint64_t maximum)
{
    return [value isKindOfClass:NSNumber.class]&&
        CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&
        !CFNumberIsFloatType((__bridge CFNumberRef)value)&&
        [value longLongValue]>=0&&[value unsignedLongLongValue]<=maximum;
}
static BOOL a5Identifier(id value)
{
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>128)return NO;
    const char *name=[value UTF8String];
    for(unsigned i=0;name[i];++i)if(!((name[i]>='a'&&name[i]<='z')||
        (name[i]>='A'&&name[i]<='Z')||name[i]=='_'||(i&&name[i]>='0'&&name[i]<='9')))return NO;
    return YES;
}
static NSUInteger a5ConstantWidth(NSUInteger type)
{
    if(type>=3&&type<=6)return 4*(type-2);
    if(type>=16&&type<=19)return 2*(type-15);
    if(type>=29&&type<=36)return 4*(1+(type-29)%4);
    if(type>=37&&type<=44)return 2*(1+(type-37)%4);
    if(type>=45&&type<=56)return 1+(type-45)%4;
    if(type>=81&&type<=88)return 8*(1+(type-81)%4);
    return 0;
}
static BOOL a5DynamicConstants(id array,BOOL indexed)
{
    if(![array isKindOfClass:NSArray.class]||[array count]>64)return NO;
    NSMutableSet *seen=[NSMutableSet set];NSString *key=indexed?@"index":@"name";
    for(NSDictionary *item in array){
        if(!a5ExactKeys(item,@[key,@"type",@"bytes",@"raw"])||
            !a5Unsigned(item[@"type"],88)||!a5Unsigned(item[@"bytes"],32))return NO;
        NSUInteger type=[item[@"type"] unsignedIntegerValue],width=a5ConstantWidth(type);
        NSString *raw=item[@"raw"];
        if(!width||[item[@"bytes"] unsignedIntegerValue]!=width||
            ![raw isKindOfClass:NSString.class]||raw.length!=width*2||
            (indexed?!a5Unsigned(item[key],65535):!a5Identifier(item[key]))||
            [seen containsObject:item[key]])return NO;
        [seen addObject:item[key]];
        for(NSUInteger i=0;i<raw.length;++i){unichar c=[raw characterAtIndex:i];
            if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}
        if(type>=53&&type<=56)for(NSUInteger i=0;i<width;++i)
            if(![[raw substringWithRange:NSMakeRange(i*2,2)] isEqual:@"00"]&&
                ![[raw substringWithRange:NSMakeRange(i*2,2)] isEqual:@"01"])return NO;
    }
    return YES;
}
#import "../../a5mali-metal/A5MaliBlendRequest.h"
#import "../../a5mali-metal/A5MaliImmutableSampler.h"
static BOOL a5DynamicRequest(NSDictionary *request,NSString *librarySHA)
{
    NSMutableDictionary *plain=[request mutableCopy];id blend=plain[@"blend_state"];
    [plain removeObjectForKey:@"blend_state"];
    if(blend&&(![request[@"stage"] isEqual:@"fragment"]||!A5MaliValidBlendRequest(blend)))return NO;
    return a5ExactKeys(plain,@[@"schema",@"kind",@"source_library",@"metallib_sha256",
        @"gpu_id",@"compiler_abi",@"stage",@"function",@"named_constants",
        @"indexed_constants",@"owner_uid",@"request_id"])&&
        a5Unsigned(request[@"schema"],1)&&[request[@"schema"] isEqual:@1]&&
        [request[@"kind"] isEqual:@"function"]&&[request[@"source_library"] isEqual:@"quartzcore"]&&
        [request[@"metallib_sha256"] isEqual:librarySHA]&&
        [request[@"gpu_id"] isEqual:@"07201000"]&&
        a5Unsigned(request[@"compiler_abi"],2)&&([request[@"compiler_abi"] isEqual:@1]||
        ([request[@"stage"] isEqual:@"fragment"]&&[request[@"compiler_abi"] isEqual:@2]))&&
        ( [request[@"stage"] isEqual:@"vertex"]||[request[@"stage"] isEqual:@"fragment"] )&&
        a5Identifier(request[@"function"])&&
        a5DynamicConstants(request[@"named_constants"],NO)&&
        a5DynamicConstants(request[@"indexed_constants"],YES);
}
static NSArray *a5DynamicConstantArguments(NSArray *named,NSArray *indexed)
{
    NSMutableArray *result=[NSMutableArray array];
    for(NSArray *list in @[named,indexed])for(NSDictionary *item in list){
        NSUInteger type=[item[@"type"] unsignedIntegerValue],components=1,unit=1;
        NSString *kind=nil;
        if(type>=3&&type<=6){kind=@"float";components=type-2;unit=4;}
        else if(type>=16&&type<=19){kind=@"half";components=type-15;unit=2;}
        else if(type>=29&&type<=36){kind=type<33?@"int":@"uint";components=1+(type-29)%4;unit=4;}
        else if(type>=37&&type<=44){kind=type<41?@"short":@"ushort";components=1+(type-37)%4;unit=2;}
        else if(type>=45&&type<=56){kind=type<49?@"char":type<53?@"uchar":@"bool";components=1+(type-45)%4;}
        else if(type>=81&&type<=88){kind=type<85?@"long":@"ulong";components=1+(type-81)%4;unit=8;}
        if(!kind)fail(@"unsupported dynamic constant data type");
        NSMutableArray *values=[NSMutableArray array];NSString *raw=item[@"raw"];
        for(NSUInteger c=0;c<components;++c){uint64_t bits=0;
            for(NSUInteger j=0;j<unit;++j){unsigned byte=0;
                [[NSScanner scannerWithString:[raw substringWithRange:NSMakeRange((c*unit+j)*2,2)]] scanHexInt:&byte];
                bits|=(uint64_t)byte<<(j*8);}
            NSString *value;
            if([kind isEqual:@"bool"])value=bits?@"true":@"false";
            else if([kind isEqual:@"float"]||[kind isEqual:@"half"])
                value=[NSString stringWithFormat:@"0x%llx",(unsigned long long)bits];
            else if([@[@"char",@"short",@"int",@"long"] containsObject:kind]){
                if(unit<8&&(bits&(UINT64_C(1)<<(unit*8-1))))bits|=UINT64_MAX<<(unit*8);
                value=[NSString stringWithFormat:@"%lld",(long long)(int64_t)bits];
            }else value=[NSString stringWithFormat:@"%llu",(unsigned long long)bits];
            [values addObject:value];
        }
        NSString *typeName=components==1?kind:[kind stringByAppendingFormat:@"%lu",(unsigned long)components];
        id key=item[@"name"]?:[item[@"index"] stringValue];
        [result addObjectsFromArray:@[@"--constant",[NSString stringWithFormat:@"%@:%@:%@",key,typeName,
            [values componentsJoinedByString:@","]]]];
    }
    return result;
}
/* These stock stages share two texture coordinates and no color varying.
 * Linking either against fixed_vert/fixed_frag is semantically invalid. */
static BOOL a5VariableBlurStage(NSDictionary *request)
{
    return ([request[@"stage"] isEqual:@"vertex"]&&
        [request[@"function"] isEqual:@"variable_blur_vert_lph"])||
        ([request[@"stage"] isEqual:@"fragment"]&&
        [request[@"function"] isEqual:@"variable_blur_downsample_frag_lph"]);
}
static NSDictionary *a5DynamicScaffold(NSDictionary *request,NSDictionary *fallback)
{
    if(!a5VariableBlurStage(request))return fallback;
    NSMutableDictionary *pair=[fallback mutableCopy];
    pair[@"vertex_function"]=@"variable_blur_vert_lph";
    pair[@"fragment_function"]=@"variable_blur_downsample_frag_lph";
    pair[@"vertex_constants"]=@[];pair[@"fragment_constants"]=@[];
    return pair;
}
static NSDictionary *a5DynamicIdentity(NSDictionary *request,BOOL success)
{
    NSMutableDictionary *identity=[@{@"schema":@2,@"kind":@"dynamic-stage",@"request_id":request[@"request_id"],
        @"source_library":@"quartzcore",@"metallib_sha256":request[@"metallib_sha256"],
        @"gpu_id":@"07201000",@"compiler_abi":request[@"compiler_abi"],@"stage":request[@"stage"],
        @"function":request[@"function"],@"stage_compiled":@(success),@"pipeline_compatible":@NO,
        @"named_constants_sha256":digest(a5Canonical(request[@"named_constants"])),
        @"indexed_constants_sha256":digest(a5Canonical(request[@"indexed_constants"])),
        @"support_generation":a5VariableBlurStage(request)?@3:@2} mutableCopy];
    if(request[@"blend_state"])identity[@"blend_state"]=request[@"blend_state"];
    return identity;
}
static void a5PublishDynamic(NSDictionary *request,NSDictionary *receipt,NSDictionary *files)
{
    NSString *key=request[@"request_id"],*final=[publishedRoot stringByAppendingPathComponent:key];
    if([NSFileManager.defaultManager fileExistsAtPath:final])return;
    NSString *work=[publishedRoot stringByAppendingPathComponent:
        [@".dynamic-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:NULL])fail(@"cannot create dynamic publication");
    NSMutableDictionary *all=[files mutableCopy];all[@"receipt.json"]=a5Canonical(receipt);
    for(NSString *name in all){NSString *path=[work stringByAppendingPathComponent:name];
        writeData(all[name],path);if(chmod(path.fileSystemRepresentation,0444))fail(@"cannot protect dynamic publication");
        int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        if(fd<0||fsync(fd)||close(fd))fail(@"cannot sync dynamic stage file");}
    if(chmod(work.fileSystemRepresentation,0755))fail(@"cannot protect dynamic publication directory");
    int fd=open(work.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0||fsync(fd)||close(fd)||rename(work.fileSystemRepresentation,final.fileSystemRepresentation))
        fail(@"cannot publish dynamic stage");
    fd=open(publishedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0||fsync(fd)||close(fd))fail(@"cannot sync dynamic publication root");
}
static void a5DynamicFailure(NSDictionary *request,NSString *reason)
{
    NSMutableDictionary *receipt=[a5DynamicIdentity(request,NO) mutableCopy];receipt[@"error"]=reason;
    a5PublishDynamic(request,receipt,@{});
    fprintf(stderr,"A5XELTE shader compiler: STAGE FAILED stage=%s request=%s reason=%s\n",
        [request[@"stage"] UTF8String],[request[@"request_id"] UTF8String],reason.UTF8String);
}

/* The 0234 worker died after saving this exact authenticated request's
 * private failure, before it had a typed public terminal receipt. Preserve
 * that old status as a typed failed receipt, so the same crash-resumable
 * retirement transaction below handles status-only and published failures.
 * The generation archive prevents a current failure from retrying forever. */
static void a5MaterializePriorBlurFailure(NSDictionary *request)
{
    if(!a5VariableBlurStage(request))return;
    NSString *key=request[@"request_id"];
    NSString *archive=[@".variable-blur-old-generation3-" stringByAppendingString:key];
    int root=open(publishedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0)fail(@"cannot open blur publication root");
    struct stat st;
    for(NSString *name in @[key,archive]){
        if(!fstatat(root,name.fileSystemRepresentation,&st,AT_SYMLINK_NOFOLLOW)){
            close(root);return;
        }
        if(errno!=ENOENT)fail(@"cannot inspect prior blur publication");
    }
    if(close(root))fail(@"cannot close prior blur publication root");
    NSString *folder=[cacheRoot stringByAppendingPathComponent:@"request-status"];
    int directory=open(folder.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(directory<0){if(errno==ENOENT)return;fail(@"untrusted prior blur status directory");}
    if(fstat(directory,&st)||st.st_uid!=geteuid()||(st.st_mode&07777)!=0700)
        fail(@"untrusted prior blur status directory");
    NSString *name=[key stringByAppendingString:@".json"];
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0){int error=errno;close(directory);if(error==ENOENT)return;
        fail(@"untrusted prior blur status");}
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||st.st_nlink!=1||
       (st.st_mode&07777)!=0600||st.st_size<=0||st.st_size>16384)
        fail(@"untrusted prior blur status");
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *cursor=data.mutableBytes;size_t left=data.length;
    while(left){ssize_t n=read(fd,cursor,left);if(n<0&&errno==EINTR)continue;
        if(n<=0)fail(@"short prior blur status");cursor+=n;left-=n;}
    uint8_t extra;if(read(fd,&extra,1)||close(fd)||close(directory))
        fail(@"prior blur status changed");
    NSDictionary *status=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(!a5ExactKeys(status,@[@"schema",@"request_id",@"status",@"reason"])||
       ![status[@"schema"] isEqual:@1]||![status[@"request_id"] isEqual:key]||
       ![status[@"status"] isKindOfClass:NSString.class]||
       ![status[@"reason"] isKindOfClass:NSString.class])fail(@"invalid prior blur status identity");
    NSString *reason=status[@"reason"];
    if(![status[@"status"] isEqual:@"failed"]||reason.length>4096||
       ![reason hasPrefix:@"compiler/validator failed; see "])return;
    NSMutableDictionary *receipt=[a5DynamicIdentity(request,NO) mutableCopy];
    receipt[@"support_generation"]=@2;receipt[@"error"]=reason;
    a5PublishDynamic(request,receipt,@{});
}

/* One generation-scoped retry per newly implemented feature. Require the
 * complete authenticated request's destination-read constants or exact stock
 * variable-blur function, together with its matching old failed receipt.
 * No successful publication, current-generation failure or other feature is
 * retired. Renamed evidence remains root-owned and cannot be overwritten.
 */
static void a5RetirePriorFeatureFailure(NSDictionary *request)
{
    BOOL blur=a5VariableBlurStage(request);
    if(!blur&&![request[@"stage"] isEqual:@"fragment"])return;
    BOOL fetch=NO,destination=NO;
    for(NSDictionary *constant in request[@"named_constants"]){
        if([constant[@"name"] isEqual:@"fc_framebuffer_fetch"])
            fetch=[constant[@"type"] isEqual:@53]&&[constant[@"raw"] isEqual:@"01"];
        if([constant[@"name"] isEqual:@"fc_dest_count"])
            destination=[constant[@"type"] isEqual:@49]&&![constant[@"raw"] isEqual:@"00"];
    }
    if(!blur&&(!fetch||!destination))return;
    NSString *key=request[@"request_id"];
    NSString *retired=[(blur?@".variable-blur-old-generation3-":@".fetch-old-generation2-") stringByAppendingString:key];
    int root=open(publishedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(root<0)fail(@"cannot open fetch publication root");
    BOOL archived=NO;
    int publication=openat(root,key.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(publication<0){
        if(errno!=ENOENT)fail(@"untrusted prior fetch publication");
        publication=openat(root,retired.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(publication<0){int error=errno;close(root);if(error==ENOENT)return;
            fail(@"untrusted retired fetch publication");}
        archived=YES;
    }
    struct stat directory,file;
    if(fstat(publication,&directory)||directory.st_uid!=geteuid()||
       (directory.st_mode&07777)!=0755)fail(@"untrusted prior fetch publication directory");
    int fd=openat(publication,"receipt.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0||fstat(fd,&file)||!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||
       file.st_nlink!=1||(file.st_mode&07777)!=0444||file.st_size<=0||file.st_size>16384)
        fail(@"untrusted prior fetch receipt");
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)file.st_size];
    size_t length=data.length;uint8_t *cursor=data.mutableBytes;
    while(length){ssize_t n=read(fd,cursor,length);if(n<0&&errno==EINTR)continue;
        if(n<=0)fail(@"short prior fetch receipt");cursor+=n;length-=n;}
    uint8_t extra;if(read(fd,&extra,1)||close(fd))fail(@"prior fetch receipt changed");
    NSDictionary *receipt=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    id generation=receipt[@"support_generation"];
    if([receipt[@"stage_compiled"] isEqual:@YES]||
       (generation&&(!blur||![generation isEqual:@2]))){
        close(publication);close(root);return;}
    NSMutableDictionary *identity=[a5DynamicIdentity(request,NO) mutableCopy];
    if(generation)identity[@"support_generation"]=generation;
    else [identity removeObjectForKey:@"support_generation"];
    NSString *reason=receipt[@"error"];
    if(![reason isKindOfClass:NSString.class]||reason.length>4096||
       ![reason hasPrefix:@"compiler/validator failed; see "]){
        close(publication);close(root);return;}
    identity[@"error"]=reason;
    if(![receipt isEqual:identity])fail(@"prior fetch receipt identity differs");
    DIR *entries=fdopendir(dup(publication));if(!entries)fail(@"cannot inspect prior fetch publication");
    struct dirent *entry;unsigned files=0;
    while((entry=readdir(entries))){if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(strcmp(entry->d_name,"receipt.json")||++files>1)fail(@"prior failed fetch contains executable artifacts");}
    if(closedir(entries)||files!=1)fail(@"invalid prior failed fetch publication");
    struct stat current;
    if(!archived&&(fstatat(root,key.fileSystemRepresentation,&current,AT_SYMLINK_NOFOLLOW)||
       current.st_dev!=directory.st_dev||current.st_ino!=directory.st_ino||
       renameatx_np(root,key.fileSystemRepresentation,root,retired.fileSystemRepresentation,RENAME_EXCL)||
       fsync(root)))fail(@"cannot retire prior fetch failure");
    if(close(publication)||close(root))fail(@"cannot close fetch publication");
    /* The failed private status would otherwise reproduce the old receipt.
     * Validate and preserve it under a non-scanned, exclusive archive name. */
    NSString *statusRoot=[cacheRoot stringByAppendingPathComponent:@"request-status"];
    int statuses=open(statusRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(statuses<0)fail(@"missing prior fetch private status");
    if(fstat(statuses,&directory)||directory.st_uid!=geteuid()||
       (directory.st_mode&07777)!=0700)fail(@"untrusted fetch status directory");
    NSString *name=[key stringByAppendingString:@".json"];
    fd=openat(statuses,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0&&errno==ENOENT){
        /* A crash between the two renames is resumed above; after the second
         * rename, no old status remains to prevent the new attempt. */
        close(statuses);return;
    }
    if(fd<0||fstat(fd,&file)||!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||
       file.st_nlink!=1||(file.st_mode&07777)!=0600||file.st_size<=0||file.st_size>16384)
        fail(@"untrusted prior fetch private status");
    data=[NSMutableData dataWithLength:(NSUInteger)file.st_size];length=data.length;cursor=data.mutableBytes;
    while(length){ssize_t n=read(fd,cursor,length);if(n<0&&errno==EINTR)continue;
        if(n<=0)fail(@"short prior fetch private status");cursor+=n;length-=n;}
    if(read(fd,&extra,1)||close(fd))fail(@"prior fetch status changed");
    NSDictionary *status=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(!a5ExactKeys(status,@[@"schema",@"request_id",@"status",@"reason"])||
        ![status[@"schema"] isEqual:@1]||![status[@"request_id"] isEqual:key]||
        ![status[@"status"] isEqual:@"failed"]||![status[@"reason"] isKindOfClass:NSString.class])
        fail(@"invalid prior fetch private status identity");
    if(![status[@"reason"] isEqual:reason]){
        /* A newly attempted compilation may itself fail. Preserve that new
         * terminal result; the archived old receipt never licenses a loop. */
        close(statuses);return;
    }
    NSString *archive=[retired stringByAppendingString:@".json"];
    if(fstatat(statuses,name.fileSystemRepresentation,&current,AT_SYMLINK_NOFOLLOW)||
       current.st_dev!=file.st_dev||current.st_ino!=file.st_ino||
       renameatx_np(statuses,name.fileSystemRepresentation,statuses,archive.fileSystemRepresentation,RENAME_EXCL)||
       fsync(statuses)||close(statuses))fail(@"cannot retire prior fetch private status");
    fprintf(stderr,"A5XELTE shader compiler: RETRY %s support_generation=%u request=%s\n",
        blur?"variable-blur-companion":"framebuffer-fetch",blur?3:2,key.UTF8String);
}

static NSNumber *a5DynamicBufferSize(NSDictionary *reflection,NSString *title,NSDictionary *slot)
{
    if(![slot[@"stage"] isEqual:title]||![slot[@"class"] isEqual:@"Buffer"]||
        !a5Unsigned(slot[@"index"],30))fail(@"invalid reflected dynamic buffer slot");
    for(NSArray *entry in reflection[@"interface"][@"slots"]){
        if(entry.count!=2)fail(@"invalid reflected interface slot");
        if(![entry[0] isEqual:slot])continue;
        NSDictionary *buffer=entry[1][@"Buffer"],*window=buffer[@"window"][@"Bounded"];
        if(![buffer[@"access"] isEqual:@{@"read":@YES,@"write":@NO}]||
            ![buffer[@"form"] isEqual:@{@"Descriptor":@"UniformWords"}]||
            ![window[@"start"] isEqual:@0]||!a5Unsigned(window[@"len"],4096)||
            ![window[@"len"] unsignedIntegerValue])fail(@"unsupported readonly dynamic buffer window");
        return window[@"len"];
    }
    fail(@"dynamic buffer specialization has no reflected slot");return nil;
}
static NSString *a5DynamicABI(NSDictionary *reflection,NSString *stage)
{
    NSString *title=[stage isEqual:@"vertex"]?@"Vertex":@"Fragment";
    NSString *shortStage=[stage isEqual:@"vertex"]?@"vert":@"frag";
    uint32_t mask=[stage isEqual:@"vertex"]?1:16;
    if(![reflection[@"kind"] isEqual:@"render"]||
        ![reflection[@"layout"] isKindOfClass:NSDictionary.class]||
        ![reflection[@"interface"] isKindOfClass:NSDictionary.class]||
        [reflection[@"interface"][@"needs_pointer_translation"] boolValue]||
        [reflection[@"interface"][@"needs_handle_translation"] boolValue])
        fail(@"dynamic stage requires reflected bounded descriptor resources");
    NSMutableString *manifest=[NSMutableString stringWithFormat:@"A5MIDGARD1\nstage %@\n",stage];
    NSUInteger pushBytes=0;
    for(NSDictionary *range in reflection[@"layout"][@"push_constants"]){
        if(!a5Unsigned(range[@"stages"],31)||!a5Unsigned(range[@"offset"],80)||
            !a5Unsigned(range[@"size"],80))fail(@"invalid reflected push range");
        if(([range[@"stages"] unsignedIntValue]&mask)!=0){
            NSUInteger end=[range[@"offset"] unsignedIntegerValue]+[range[@"size"] unsignedIntegerValue];
            if(end>80||end%4)fail(@"dynamic push constants exceed aligned80 bytes");pushBytes=MAX(pushBytes,end);}
    }
    [manifest appendFormat:@"push_bytes %lu\n",(unsigned long)pushBytes];
    unsigned resources=0,textures=0,fetches=0;
    if([reflection[@"layout"][@"sets"] count]!=1)fail(@"dynamic stage requires exactly descriptor set0");
    for(NSDictionary *set in reflection[@"layout"][@"sets"]){
        if(![set[@"set"] isEqual:@0]||[set[@"flags"] unsignedIntegerValue])fail(@"dynamic stage only supports descriptor set0");
        for(NSDictionary *binding in set[@"bindings"]){
            if(!a5Unsigned(binding[@"stages"],31))fail(@"invalid reflected binding stage");
            if(!([binding[@"stages"] unsignedIntValue]&mask))continue;
            if(!a5Unsigned(binding[@"binding"],30)||![binding[@"count"] isEqual:@1]||
                [binding[@"flags"] unsignedIntegerValue]||++resources>32)fail(@"dynamic binding count/index exceeds ABI");
            NSUInteger index=[binding[@"binding"] unsignedIntegerValue],type=[binding[@"ty"] unsignedIntegerValue];
            if(type==6){
                if(index>=7)fail(@"dynamic native UBO table overflow");
                NSNumber *bytes=a5DynamicBufferSize(reflection,title,binding[@"source"][@"Buffer"]);
                [manifest appendFormat:@"binding %lu uniform %@\n",(unsigned long)index,bytes];
            }else if(type==7&&[binding[@"source"] isEqual:@{@"Synthetic":@{@"stage":title,@"binding":@"ConstantBlob"}}]){
                [manifest appendFormat:@"binding %lu storage 0\n",(unsigned long)index];
            }else if(type==1){
                NSDictionary *source=binding[@"source"][@"CombinedTextureSampler"];
                NSDictionary *texture=source[@"texture"],*sampler=source[@"sampler"];
                NSDictionary *selection=sampler[@"sampler"];
                if(selection[@"Constexpr"]){
                    if(!A5MaliDecodeImmutableSampler(binding[@"immutable_sampler"],textures,NULL))
                        fail(@"unsupported immutable dynamic sampler state");
                }else if(!a5ExactKeys(selection,@[@"Slot"])||
                    binding[@"immutable_sampler"]!=NSNull.null)
                    fail(@"unsupported dynamic sampler source");
                NSDictionary *textureInfo=nil;
                for(NSArray *slot in reflection[@"interface"][@"slots"])
                    if(slot.count==2&&[slot[0] isEqual:texture])textureInfo=slot[1][@"Texture"];
                if(textures>=4||![texture[@"stage"] isEqual:title]||
                    ![textureInfo[@"texture_type"] isEqual:@"Type2D"]||
                    ![textureInfo[@"sampled_type"] isEqual:@"Float"]||
                    [textureInfo[@"depth_compare"] boolValue]||
                    ![textureInfo[@"access"] isEqual:@{@"sample":@YES,@"read":@NO,@"write":@NO}]||
                    [sampler[@"compare"] boolValue]||[sampler[@"integer"] boolValue]||
                    [sampler[@"cube_gradient"] boolValue]||[sampler[@"raw"] boolValue])
                    fail(@"unsupported dynamic sampled texture ABI");
                [manifest appendFormat:@"texture %lu %u\n",(unsigned long)index,textures++];}
            else if(type==10&&[stage isEqual:@"fragment"]&&
                [binding[@"source"] isEqual:@{@"InputAttachment":@0}]){
                NSDictionary *graphics=reflection[@"graphics"];
                if(fetches++||![graphics[@"rasterization_order_attachment_access"] isEqual:@YES]||
                    ![graphics[@"rasterization_samples"] isEqual:@1]||
                    ![graphics[@"input_attachments"] isEqual:@[@{@"color_index":@0,
                       @"input_attachment_index":@0,@"format_class":@"Float"}]])
                    fail(@"unsupported unordered or multisampled framebuffer fetch");
                [manifest appendFormat:@"framebuffer_fetch %lu 0\n",(unsigned long)index];
            }else fail(@"dynamic descriptor kind requires a new lowering");
        }
    }
    NSDictionary *selected=nil;
    for(NSDictionary *entry in reflection[@"stages"])if([entry[@"stage"] isEqual:shortStage]){
        if(selected)fail(@"duplicate reflected stage");selected=entry;}
    if(!selected||![selected[@"entry_point"] isEqual:@"main"]||
        [selected[@"stage_flags"] unsignedIntegerValue]||selected[@"required_subgroup_size"]!=NSNull.null)
        fail(@"requested stage execution model unsupported");
    unsigned specs=0;
    for(NSDictionary *constant in selected[@"specialization"][@"constants"]){
        if(!a5Unsigned(constant[@"id"],65535)||![constant[@"size"] isEqual:@4]||++specs>16)
            fail(@"dynamic specialization shape exceeds ABI");
        NSDictionary *key=constant[@"key"];NSNumber *value=nil;
        NSDictionary *range=key[@"RangeAtBindOffset"];
        if(range){value=a5DynamicBufferSize(reflection,title,range);
        }else if(key[@"SamplerState"]){
            NSDictionary *sampler=key[@"SamplerState"];
            if(![sampler[@"slot"][@"stage"] isEqual:title]||
                !a5Unsigned(sampler[@"slot"][@"index"],15)||
                ![sampler[@"slot"][@"class"] isEqual:@"Sampler"]||
                ![sampler[@"fields"] isEqual:@2147483655]||
                ![constant[@"unread_bits"] isEqual:@4294967288])fail(@"invalid sampler specialization");
            /* Normalized coordinates with run-time sampler filtering/address
             * parameters. The chosen word is retained in the root receipt. */
            value=@0;
        }
        if(!value)fail(@"dynamic specialization key requires a new lowering");
        [manifest appendFormat:@"spec %@ %@\n",constant[@"id"],value];
    }
    return manifest;
}
static void a5CompileDynamic(NSString *self,NSDictionary *request,NSDictionary *scaffold)
{
    NSString *key=request[@"request_id"],*stage=request[@"stage"];
    NSString *final=[publishedRoot stringByAppendingPathComponent:key];
    if([NSFileManager.defaultManager fileExistsAtPath:final])return;
    scaffold=a5DynamicScaffold(request,scaffold);
    activeRequestKey=key;
    activeDynamicRequest=[request copy];
    serviceCheckpoint("dispatch",key,stage);
    NSString *work=[cacheRoot stringByAppendingPathComponent:
        [@".stage-work-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    serviceCheckpoint("workspace-mkdir-begin",key,stage);
    if(![NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:NULL])fail(@"cannot create dynamic stage workspace");
    serviceCheckpoint("workspace-mkdir-end",key,stage);
    activeWork=work;
    BOOL vertex=[stage isEqual:@"vertex"];
    NSString *prefix=[work stringByAppendingPathComponent:@"shader"];
    NSString *meta=[work stringByAppendingPathComponent:@"reflection.json"];
    NSString *packing=[work stringByAppendingPathComponent:@"packing0.json"];
    serviceCheckpoint("packing-write-sync-begin",key,stage);
    writeData(a5Canonical(scaffold[@"configured_vertex_packing0"]),packing);
    serviceCheckpoint("packing-write-sync-end",key,stage);
    /* This compiler contract is implemented by the native color0 tilebuffer
     * read, target preload and ordered-fragment runtime, not a Vulkan device.
     * Keep the installed baseline unchanged for the pinned old recipes. */
    serviceCheckpoint("profile-read-begin",key,stage);
    NSMutableDictionary *deviceProfile=[NSJSONSerialization JSONObjectWithData:
        regularData([installed stringByAppendingPathComponent:@"profile.json"],1024*1024)
        options:NSJSONReadingMutableContainers error:NULL];
    serviceCheckpoint("profile-read-end",key,stage);
    NSMutableDictionary *capabilities=deviceProfile[@"capabilities"];
    NSMutableDictionary *profiles=deviceProfile[@"profiles"];
    if(![capabilities isKindOfClass:NSMutableDictionary.class]||
        ![profiles isKindOfClass:NSMutableDictionary.class]||profiles.count!=1)
        fail(@"invalid baseline compiler device profile");
    capabilities[@"a5_ordered_tilebuffer_color0"]=@{
      @"extensions":@{@"VK_EXT_rasterization_order_attachment_access":@1},@"features":@{
        @"VkPhysicalDeviceRasterizationOrderAttachmentAccessFeaturesEXT":@{
            @"rasterizationOrderColorAttachmentAccess":@YES,
            @"rasterizationOrderDepthAttachmentAccess":@NO,
            @"rasterizationOrderStencilAttachmentAccess":@NO}}};
    NSMutableDictionary *selectedProfile=profiles.allValues.firstObject;
    NSMutableArray *selectedCapabilities=selectedProfile[@"capabilities"];
    if(![selectedCapabilities isKindOfClass:NSMutableArray.class])
        fail(@"invalid baseline compiler capability list");
    [selectedCapabilities addObject:@"a5_ordered_tilebuffer_color0"];
    NSString *deviceProfilePath=[work stringByAppendingPathComponent:@"ordered-color0-profile.json"];
    serviceCheckpoint("profile-write-sync-begin",key,stage);
    writeData(a5Canonical(deviceProfile),deviceProfilePath);
    serviceCheckpoint("profile-write-sync-end",key,stage);
    /* The translator currently exposes a render-pair CLI. A trusted stock
     * companion supplies stage-link scaffolding; only the requested stage is
     * compiled/published and the companion is not an executable-pipeline claim. */
    NSMutableDictionary *constants=[NSMutableDictionary dictionary];
    /* Both translation companions need their real specialization values.
     * Empty fragment constants must not leave the scaffold vertex's required
     * fc_generic/fc_texcoord_count values undefined. Requested values override
     * shared names; only the requested native stage is published. */
    for(NSDictionary *item in scaffold[vertex?@"fragment_constants":@"vertex_constants"])
        constants[item[@"name"]]=item;
    for(NSDictionary *item in request[@"named_constants"])constants[item[@"name"]]=item;
    NSArray *named=[[constants allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"name"] compare:b[@"name"]];}];
    NSMutableArray *air=[NSMutableArray arrayWithArray:@[
        [installed stringByAppendingPathComponent:@"metal2vulkan"],sourceLibrary,
        [prefix stringByAppendingString:@".spv"],@"--profile",deviceProfilePath,
        @"--function",vertex?request[@"function"]:scaffold[@"vertex_function"],
        @"--fragment",vertex?scaffold[@"fragment_function"]:request[@"function"],
        @"--color-format",@"0:BGRA8Unorm",@"--vertex-descriptor",packing,@"--emit-meta",meta,@"--no-timeout"]];
    [air addObjectsFromArray:a5DynamicConstantArguments(named,request[@"indexed_constants"])];
    setenv("METAL2VULKAN_SPIRV_VAL",[installed stringByAppendingPathComponent:@"spirv-val"].fileSystemRepresentation,1);
    run(self,air,[work stringByAppendingPathComponent:@"air.log"]);
    NSString *text=[[NSString alloc]initWithData:regularData([work stringByAppendingPathComponent:@"air.log"],8*1024*1024) encoding:NSUTF8StringEncoding];
    if(![text containsString:@"spirv-val vulkan1.2: PASS"])fail(@"dynamic SPIR-V validation did not run");
    NSDictionary *reflection=readJSON(meta);
    NSString *manifest=a5DynamicABI(reflection,stage),*abiPath=[work stringByAppendingPathComponent:@"ABI.txt"];
    if(request[@"blend_state"]){NSDictionary *b=request[@"blend_state"];
        manifest=[manifest stringByAppendingFormat:@"blend %u %u %u %u %u %u %u %u\n",
            [b[@"format"] unsignedIntValue],[b[@"write_mask"] unsignedIntValue],
            [b[@"rgb_operation"] unsignedIntValue],[b[@"alpha_operation"] unsignedIntValue],
            [b[@"source_rgb"] unsignedIntValue],[b[@"destination_rgb"] unsignedIntValue],
            [b[@"source_alpha"] unsignedIntValue],[b[@"destination_alpha"] unsignedIntValue]];
    }
    writeData([manifest dataUsingEncoding:NSUTF8StringEncoding],abiPath);
    NSString *shortStage=vertex?@"vert":@"frag";
    NSString *nativePath=[work stringByAppendingPathComponent:@"stage.midgard"];
    NSString *infoPath=[work stringByAppendingPathComponent:@"info.json"];
    run(self,@[[installed stringByAppendingPathComponent:@"midgard-generic602"],@"--dynamic-stage",stage,
        [prefix stringByAppendingFormat:@".%@.spv",shortStage],nativePath,abiPath,infoPath],
        [work stringByAppendingPathComponent:@"midgard.log"]);
    NSData *native=regularData(nativePath,1024*1024);NSDictionary *info=readJSON(infoPath);
    NSDictionary *stats=info[@"native_info"];
    if(![info[@"schema"] isEqual:@1]||![info[@"stage"] isEqual:stage]||
        ![stats isKindOfClass:NSDictionary.class]||![stats[@"bytes"] isEqual:@(native.length)]||
        !a5Unsigned(stats[@"first_tag"],15)||![stats[@"first_tag"] unsignedIntegerValue]||
        [stats[@"first_tag"] unsignedIntegerValue]!=(((const uint8_t*)native.bytes)[0]&15)||
        !a5Unsigned(stats[@"work_regs"],32)||!a5Unsigned(stats[@"tls"],1024*1024)||
        !a5Unsigned(stats[@"wls"],1024*1024))fail(@"dynamic native compiler metadata differs from code");
    NSMutableDictionary *semantic=[reflection mutableCopy];NSMutableArray *stages=[NSMutableArray array];
    for(NSDictionary *entry in reflection[@"stages"]){NSMutableDictionary *clean=[entry mutableCopy];
        clean[@"spirv"]=[NSString stringWithFormat:@"shader.%@.spv",entry[@"stage"]];[stages addObject:clean];}
    semantic[@"stages"]=stages;
    semantic[@"compilation_context"]=@{@"kind":@"render-pair-scaffold",@"requested_stage":stage,
        @"requested_function":request[@"function"],@"companion_function":vertex?scaffold[@"fragment_function"]:scaffold[@"vertex_function"],
        @"selected_native_stage_only":@YES,@"native_manifest":manifest,
        @"translation_named_constants":named,@"translation_indexed_constants":request[@"indexed_constants"],
        @"vertex_descriptor":scaffold[@"configured_vertex_packing0"]};
    NSData *reflectionData=a5Canonical(semantic);
    NSMutableDictionary *receipt=[a5DynamicIdentity(request,YES) mutableCopy];
    receipt[@"native"]=@{@"file":@"stage.midgard",@"bytes":@(native.length),@"sha256":digest(native),
        @"first_tag":stats[@"first_tag"],@"work_registers":stats[@"work_regs"],@"tls_bytes":stats[@"tls"],@"wls_bytes":stats[@"wls"]};
    receipt[@"reflection"]=@{@"file":@"reflection.json",@"bytes":@(reflectionData.length),@"sha256":digest(reflectionData)};
    if([request[@"compiler_abi"] isEqual:@2]&&![info[@"shader_anisotropy"] isEqual:@1])
        fail(@"fragment compiler generation2 lacks actual shader anisotropy lowering");
    receipt[@"native_abi"]=info;
    a5PublishDynamic(request,receipt,@{@"stage.midgard":native,@"reflection.json":reflectionData});
    activeDynamicRequest=nil;
    [NSFileManager.defaultManager removeItemAtPath:work error:NULL];activeWork=nil;activeRequestKey=nil;
    fprintf(stderr,"A5XELTE shader compiler: STAGE PUBLISHED stage=%s function=%s bytes=%lu request=%s\n",
        stage.UTF8String,[request[@"function"] UTF8String],(unsigned long)native.length,key.UTF8String);
}

/* An earlier unsupported request may become executable after a compiler
 * upgrade. Retry only an exact606 pair or a complete validated dynamic-stage
 * request. Status files remain root-private, bounded and non-linkable;
 * genuine failed/other statuses remain terminal. */
static BOOL a5HasTerminalRequestStatus(NSString *key, NSDictionary *known, NSDictionary *dynamicRequest)
{
    NSString *folder=[cacheRoot stringByAppendingPathComponent:@"request-status"];
    int directory=open(folder.fileSystemRepresentation,
        O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(directory<0){if(errno==ENOENT)return NO;
        fail(@"untrusted request status directory");}
    struct stat st;
    if(fstat(directory,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||
        (st.st_mode&07777)!=0700)fail(@"untrusted request status directory");
    NSString *name=[key stringByAppendingString:@".json"];
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0){if(errno==ENOENT){close(directory);return NO;}
        fail(@"untrusted existing request status");}
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||
        st.st_nlink!=1||(st.st_mode&07777)!=0600||st.st_size<=0||st.st_size>16384)
        fail(@"untrusted existing request status");
    if(!dynamicRequest&&![known[@"profile_id"] isEqual:@606]){close(fd);close(directory);return YES;}
    NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *cursor=bytes.mutableBytes;size_t left=bytes.length;
    while(left){ssize_t n=read(fd,cursor,left);if(n<0&&errno==EINTR)continue;
        if(n<=0)fail(@"short existing request status read");cursor+=n;left-=(size_t)n;}
    uint8_t extra;if(read(fd,&extra,1)!=0||close(fd))
        fail(@"existing request status size changed");
    NSDictionary *record=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
    if(!a5ExactKeys(record,@[@"schema",@"request_id",@"status",@"reason"])||
        ![record[@"schema"] isEqual:@1]||![record[@"request_id"] isEqual:key]||
        ![record[@"status"] isKindOfClass:NSString.class]||
        ![record[@"reason"] isKindOfClass:NSString.class])
        fail(@"untrusted existing request status identity");
    if(![record[@"status"] isEqual:@"unsupported"]){
        close(directory);
        if(dynamicRequest&&[record[@"status"] isEqual:@"failed"])
            a5DynamicFailure(dynamicRequest,record[@"reason"]);
        return YES;
    }
    struct stat current;
    if(fstatat(directory,name.fileSystemRepresentation,&current,AT_SYMLINK_NOFOLLOW)||
        current.st_dev!=st.st_dev||current.st_ino!=st.st_ino||
        current.st_uid!=st.st_uid||current.st_mode!=st.st_mode||current.st_nlink!=1||
        current.st_size!=st.st_size||
        unlinkat(directory,name.fileSystemRepresentation,0)||fsync(directory)||close(directory))
        fail(@"cannot retire unsupported 606 request status");
    fprintf(stderr,"A5XELTE shader compiler: RETRY newly supported %s request=%s\n",
        dynamicRequest?"dynamic-stage":"profile=606",key.UTF8String);
    return NO;
}

static void a5HandleRequest(NSString *self, NSDictionary *request,
                            NSArray<NSDictionary *> *knownProfiles, NSString *key)
{
    NSDictionary *known = nil;
    for (NSDictionary *candidate in knownProfiles) {
        if (a5KnownProfile(request,candidate)) { known = candidate; break; }
    }
    NSDictionary *scaffold=nil;
    for(NSDictionary *candidate in knownProfiles)if([candidate[@"profile_id"] isEqual:@603])scaffold=candidate;
    BOOL dynamic=scaffold&&a5DynamicRequest(request,scaffold[@"metallib_sha256"]);
    if(dynamic){a5MaterializePriorBlurFailure(request);a5RetirePriorFeatureFailure(request);}
    if(dynamic&&[NSFileManager.defaultManager fileExistsAtPath:
        [publishedRoot stringByAppendingPathComponent:key]])return;
    if (a5HasTerminalRequestStatus(key,known,dynamic?request:nil)) return;
    if(dynamic){a5CompileDynamic(self,request,scaffold);return;}
    if ([known[@"profile_id"] isEqual:@603]) {
        if(a5PublishedCurrentOrRetire603(key,known))return;
    } else if ([NSFileManager.defaultManager fileExistsAtPath:
        [publishedRoot stringByAppendingPathComponent:key]]) return;
    if (!known) {
        a5WriteStatus(key,@"unsupported",
            @"Only exact captured 602 or candidate 603/604/605/606 fixed_vert_lph_spc/fixed_frag_lph_cph typed pairs compile; other requests remain unsupported.");
        fprintf(stderr,"A5XELTE shader compiler: UNSUPPORTED request=%s\n",key.UTF8String);
        return;
    }
    a5CompileKnown(self,request,known);
}

#include "a5shader_retirement.inc.m"

/* A fixed snapshot may take long enough for a compositor to enqueue a new
 * function. Recheck names between old handlers, reading only unseen leaves.
 * Both per-UID enumeration and total newly inspected leaves are bounded64.
 * Presence checks affect ordering only; identity and dynamic admission remain
 * mandatory before the existing handler can compile anything. */
static unsigned a5DispatchArrivingFunctions(NSString *self,NSArray *profiles,int rootfd,
    NSMutableSet *seen,unsigned *remaining)
{
    if(!*remaining)return 0;
    NSString *librarySHA=nil;
    for(NSDictionary *profile in profiles)if([profile[@"profile_id"] isEqual:@603])librarySHA=profile[@"metallib_sha256"];
    if(!librarySHA)return 0;
    /* openat creates an independent directory position; dup would share the
     * initial reader's end-of-directory offset on HFS. */
    int scanfd=openat(rootfd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *users=scanfd>=0?fdopendir(scanfd):NULL;
    if(!users){if(scanfd>=0)close(scanfd);return 0;}
    unsigned dispatched=0;struct dirent *user;
    while(*remaining&&(user=readdir(users))){
        NSString *component=[NSString stringWithUTF8String:user->d_name];
        if(!component.length||[component rangeOfCharacterFromSet:
            [NSCharacterSet.decimalDigitCharacterSet invertedSet]].location!=NSNotFound)continue;
        unsigned long long number=strtoull(user->d_name,NULL,10);if(number>UINT32_MAX)continue;
        uid_t uid=(uid_t)number;
        for(int lane=1;lane>=0;lane--){
        int dir=A5MaliOpenShaderLane(rootfd,uid,(unsigned)lane,0);
        if(dir<0)continue;
        DIR *files=fdopendir(dup(dir));if(!files){close(dir);continue;}
        unsigned count=0;struct dirent *entry;
        while(*remaining&&count<64&&(entry=readdir(files))){
            NSString *name=[NSString stringWithUTF8String:entry->d_name];
            if(![name hasSuffix:@".request.json"]||name.length!=77)continue;
            NSString *key=[name substringToIndex:64];if(!a5HexDigest(key))continue;
            count++;
            if([seen containsObject:key])continue;
            [seen addObject:key];(*remaining)--;
            NSString *publication=[publishedRoot stringByAppendingPathComponent:key];
            NSString *status=[[cacheRoot stringByAppendingPathComponent:@"request-status"]
                stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
            if([NSFileManager.defaultManager fileExistsAtPath:publication]||
                [NSFileManager.defaultManager fileExistsAtPath:status])continue;
            NSData *bytes=a5ReadRequest(dir,entry->d_name,uid);
            NSDictionary *request=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
            if(![request isKindOfClass:NSDictionary.class]||![request[@"request_id"] isEqual:key]||
                ![request[@"owner_uid"] isEqual:@(uid)])continue;
            NSMutableDictionary *body=[request mutableCopy];[body removeObjectForKey:@"request_id"];
            NSData *canonical=a5Canonical(body);
            if(!canonical||![digest(canonical) isEqual:key]||!a5DynamicRequest(request,librarySHA))continue;
            if([NSFileManager.defaultManager fileExistsAtPath:[publishedRoot stringByAppendingPathComponent:key]])continue;
            serviceCheckpoint("arriving-function",key,request[@"stage"]);
            a5HandleRequest(self,request,profiles,key);dispatched++;
        }
        closedir(files);close(dir);
        }
    }
    closedir(users);return dispatched;
}
#ifdef A5_SHADER_SCAN_HOST_TEST
static void (*a5ScanAfterSnapshot)(void);
static void (*a5ScanBeforeOldHandler)(NSDictionary *);
#endif

static void a5ScanRequests(NSString *self, NSArray<NSDictionary *> *knownProfiles)
{
    static unsigned scans;
    static NSString *maintenanceCursor;
    unsigned scan=++scans;
    BOOL report=scan<=8;
    __block unsigned usersSeen=0,usersRejected=0,candidates=0,readRejected=0,
        jsonRejected=0,identityRejected=0,digestRejected=0,handled=0,capped=0;
    if(report)serviceCheckpoint("scan-begin",nil,nil);
    int rootfd=open(requestRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(rootfd<0){
        if(report)fprintf(stderr,"A5XELTE shader compiler: SCAN scan=%u root_open_errno=%d\n",scan,errno);
        return;
    }
    struct stat rootstat;
    if(fstat(rootfd,&rootstat)||!S_ISDIR(rootstat.st_mode)||rootstat.st_uid!=geteuid()||
        (rootstat.st_mode&07777)!=01777)fail(@"untrusted shader request spool root");
    DIR *users=fdopendir(dup(rootfd));if(!users)fail(@"cannot enumerate request spool");
    NSMutableArray *urgentNames=[NSMutableArray array],*oldNames=[NSMutableArray array];
    NSMutableSet *seen=[NSMutableSet set];
    NSMutableDictionary *uidCandidates=[NSMutableDictionary dictionary];
    struct dirent *user;
    /* Enumerate metadata first. Never read all old request bodies before a
     * newly queued specialization. Output/status presence is only a priority
     * hint, never proof of identity, shader admission or terminal durability. */
    while((user=readdir(users))){
        NSString *component=[NSString stringWithUTF8String:user->d_name];
        if(!component.length||[component rangeOfCharacterFromSet:
            [NSCharacterSet.decimalDigitCharacterSet invertedSet]].location!=NSNotFound)continue;
        unsigned long long number=strtoull(user->d_name,NULL,10);if(number>UINT32_MAX)continue;
        usersSeen++;uid_t uid=(uid_t)number;
        for(int lane=1;lane>=0;lane--){
        int dir=A5MaliOpenShaderLane(rootfd,uid,(unsigned)lane,0);
        if(dir<0){if(!lane)usersRejected++;continue;}
        DIR *files=fdopendir(dup(dir));if(!files){usersRejected++;close(dir);continue;}
        unsigned count=0;struct dirent *entry;
        while(count<64&&(entry=readdir(files))){
            NSString *name=[NSString stringWithUTF8String:entry->d_name];
            if(![name hasSuffix:@".request.json"]||name.length!=77)continue;
            NSString *key=[name substringToIndex:64];if(!a5HexDigest(key))continue;
            count++;candidates++;if([seen containsObject:key])continue;[seen addObject:key];
            NSString *laneKey=[component stringByAppendingFormat:@"/%d",lane];
            NSDictionary *meta=@{@"user":component,@"uid":@(uid),@"lane":@(lane),@"laneKey":laneKey,@"name":name,@"key":key,
                @"token":[laneKey stringByAppendingFormat:@"/%@",key]};
            NSString *publication=[publishedRoot stringByAppendingPathComponent:key];
            NSString *status=[[cacheRoot stringByAppendingPathComponent:@"request-status"]
                stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
            if([NSFileManager.defaultManager fileExistsAtPath:publication]||
                [NSFileManager.defaultManager fileExistsAtPath:status])[oldNames addObject:meta];
            else [urgentNames addObject:meta];
        }
        if(count==64)capped++;
        uidCandidates[[component stringByAppendingFormat:@"/%d",lane]]=@(count);closedir(files);close(dir);
        }
    }
    closedir(users);
#ifdef A5_SHADER_SCAN_HOST_TEST
    if(a5ScanAfterSnapshot)a5ScanAfterSnapshot();
#endif
    NSDictionary *(^readSnapshot)(NSDictionary *)=^NSDictionary *(NSDictionary *meta){
        uid_t uid=[meta[@"uid"]unsignedIntValue];NSString *key=meta[@"key"];
        int dir=A5MaliOpenShaderLane(rootfd,uid,[meta[@"lane"]unsignedIntValue],0);
        struct stat st;NSData *bytes=nil;
        if(dir>=0&&!fstat(dir,&st)&&S_ISDIR(st.st_mode)&&st.st_uid==uid&&(st.st_mode&0777)==0700)
            bytes=a5ReadRequest(dir,[meta[@"name"]fileSystemRepresentation],uid);
        if(dir>=0)close(dir);
        if(!bytes){readRejected++;return nil;}
        NSDictionary *request=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        if(![request isKindOfClass:NSDictionary.class]){jsonRejected++;return nil;}
        if(![request[@"request_id"]isEqual:key]||![request[@"owner_uid"]isEqual:@(uid)]){
            identityRejected++;return nil;}
        NSMutableDictionary *body=[request mutableCopy];[body removeObjectForKey:@"request_id"];
        NSData *canonical=a5Canonical(body);
        if(!canonical||![digest(canonical)isEqual:key]){digestRejected++;return nil;}
        NSMutableDictionary *snapshot=[meta mutableCopy];snapshot[@"request"]=request;snapshot[@"bytes"]=bytes;
        return snapshot;
    };
    NSMutableArray *functions=[NSMutableArray array],*others=[NSMutableArray array],*completed=[NSMutableArray array];
    for(NSDictionary *meta in urgentNames){
        NSDictionary *snapshot=readSnapshot(meta);if(!snapshot)continue;
        if([snapshot[@"request"][@"kind"]isEqual:@"function"])[functions addObject:snapshot];
        else [others addObject:snapshot];
    }
    for(NSArray *batch in @[functions,others])for(NSDictionary *snapshot in batch){
        NSDictionary *request=snapshot[@"request"];handled++;
        a5HandleRequest(self,request,knownProfiles,request[@"request_id"]);
        [completed addObject:snapshot];
    }
    /* One fresh-name pass per scan, replacing the previous per-old-handler
     * rescans. Arrivals get real authentication/compilation before maintenance. */
    unsigned arrivalBudget=64;
    unsigned arrivals=a5DispatchArrivingFunctions(self,knownProfiles,rootfd,seen,&arrivalBudget);
    unsigned maintenance=0;
    if(!arrivals&&arrivalBudget&&oldNames.count){
        NSArray *ordered=[oldNames sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            return [a[@"token"]compare:b[@"token"]];}];
        NSDictionary *selected=ordered.firstObject;
        for(NSDictionary *meta in ordered)if(!maintenanceCursor||[meta[@"token"]compare:maintenanceCursor]==NSOrderedDescending){
            selected=meta;break;}
        /* Advance even for a corrupt or replaced leaf so it cannot starve
         * old603 migration, retryable statuses or another UID's maintenance. */
        maintenanceCursor=[selected[@"token"]copy];maintenance=1;
        NSDictionary *snapshot=readSnapshot(selected);
        if(snapshot){
            NSDictionary *request=snapshot[@"request"];
#ifdef A5_SHADER_SCAN_HOST_TEST
            if(a5ScanBeforeOldHandler)a5ScanBeforeOldHandler(request);
#endif
            serviceCheckpoint("old-maintenance",request[@"request_id"],nil);
            handled++;a5HandleRequest(self,request,knownProfiles,request[@"request_id"]);
            [completed insertObject:snapshot atIndex:0];
        }
    }
    /* At63/64 quota pressure, one fresh locked terminal retirement attempt.
     * Mere publication/status presence above can never authorize deletion. */
    for(NSDictionary *snapshot in completed){
        if(arrivals||!arrivalBudget)break;
        if([uidCandidates[snapshot[@"laneKey"]]unsignedIntValue]<63)continue;
        NSDictionary *request=snapshot[@"request"];
        if(!a5RetireTerminal(request,knownProfiles))continue;
        int dir=A5MaliOpenShaderLane(rootfd,[snapshot[@"uid"]unsignedIntValue],[snapshot[@"lane"]unsignedIntValue],0);
        if(dir>=0){a5RetireCompletedRequest(dir,[snapshot[@"name"]fileSystemRepresentation],
            [snapshot[@"uid"]unsignedIntValue],snapshot[@"bytes"],request,knownProfiles);close(dir);}
        break;
    }
    close(rootfd);
    if(report){
        fprintf(stderr,"A5XELTE shader compiler: SCAN scan=%u users=%u users_rejected=%u candidates=%u read_rejected=%u json_rejected=%u identity_rejected=%u digest_rejected=%u handled=%u capped_users=%u deferred_old=%lu maintenance=%u arrivals=%u\n",
            scan,usersSeen,usersRejected,candidates,readRejected,jsonRejected,identityRejected,digestRejected,handled,capped,
            (unsigned long)oldNames.count,maintenance,arrivals);
        fflush(stderr);serviceCheckpoint("scan-end",nil,nil);
    }
}

static void a5Serve(NSString *self)
{
    serviceCheckpoint("serve-roots-begin",nil,nil);
    a5PrepareRequestRoots();
    serviceCheckpoint("serve-roots-end",nil,nil);
    NSMutableArray<NSDictionary *> *knownProfiles = [NSMutableArray array];
    serviceCheckpoint("stock-read-begin",nil,nil);
    NSData *source=regularData(sourceLibrary,64*1024*1024);
    serviceCheckpoint("stock-read-end",nil,nil);
    serviceCheckpoint("stock-hash-begin",nil,nil);
    NSString *sourceSHA = digest(source);
    serviceCheckpoint("stock-hash-end",nil,nil);
    for (NSNumber *profile in @[@602,@603,@604,@605,@606]) {
        serviceCheckpoint("recipe-read-begin",nil,profile.stringValue);
        NSString *name = [NSString stringWithFormat:@"generic%@.json",profile];
        NSDictionary *known = readJSON([installed stringByAppendingPathComponent:name]);
        if (![known[@"profile_id"] isEqual:profile] ||
            ![sourceSHA isEqual:known[@"metallib_sha256"]])
            fail(@"installed generic recipe or stock library differs");
        [knownProfiles addObject:known];
        serviceCheckpoint("recipe-read-end",nil,profile.stringValue);
    }
    for (;;) {
        @autoreleasepool { a5ScanRequests(self,knownProfiles); }
        sleep(5);
    }
}
