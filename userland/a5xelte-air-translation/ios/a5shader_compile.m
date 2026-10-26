/* SPDX-License-Identifier: MIT
 * Native iOS orchestration of the real AIR -> SPIR-V -> T720 compiler.
 * No GPU submission or fallback shader is performed here.
 */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/IOKitLib.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
extern char **environ;
/* libproc exports are in libSystem on iOS; the public iPhone SDK omits its
 * header. These prototypes match XNU/libproc, with sys/resource.h types. */
extern int proc_listpgrppids(pid_t, void *, int);
extern int proc_pid_rusage(int, int, rusage_info_t *);
extern int proc_pidpath(int, void *, uint32_t) __attribute__((weak_import));

#ifndef A5_SHADER_HOST_TEST
static NSString *const installed = @"/usr/libexec/a5shader";
static NSString *const cacheRoot = @"/private/var/db/a5shader-cache";
static NSString *const sourceLibrary = @"/System/Library/Frameworks/QuartzCore.framework/default.metallib";
#else
/* Compiled only by the host regression; no runtime path overrides on iOS. */
static NSString *const installed = @A5_TEST_TOOLS;
static NSString *const cacheRoot = @A5_TEST_CACHE;
static NSString *const sourceLibrary = @A5_TEST_LIBRARY;
#endif
static NSString *activeWork;
static NSString *activeRequestKey;
/* A validated function request must receive a public terminal receipt even
 * when its compiler child fails and this service exits before another scan. */
static NSDictionary *activeDynamicRequest;
static void a5DynamicFailure(NSDictionary *request,NSString *reason);
static void a5WriteStatus(NSString *key, NSString *status, NSString *reason);
static NSSet<NSString *> *a5RunnableFunctionKeys(void);
static BOOL a5DemandYielded;
#ifdef A5_SHADER_RUN_HOST_TEST
static NSArray<NSString *> *(^a5RunTestReplacement)(NSArray<NSString *> *);
#endif

static void fail(NSString *reason);

static void showSuccess(void)
{
#ifndef A5_SHADER_HOST_TEST
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("A5XELTEGPU"));
    if (!service) fail(@"compiler completion service unavailable");
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service,mach_task_self(),1,&connection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) fail(@"compiler completion client denied");
    const uint32_t report[6] = {1,24,0,0,3,0};
    size_t outputSize = 0;
    kr = IOConnectCallStructMethod(connection,16,report,sizeof(report),NULL,&outputSize);
    IOServiceClose(connection);
    if (kr != KERN_SUCCESS || outputSize) fail(@"compiler green completion line failed");
    fprintf(stderr,"A5XELTE shader compiler: GREEN LINE verified_pairs=3\n");
#else
    fprintf(stderr,"A5XELTE shader compiler: host test skips device completion line\n");
#endif
}

static void fail(NSString *reason)
{
    fprintf(stderr, "A5XELTE shader compiler: FAILED %s\n", reason.UTF8String);
    if (activeWork) {
        for (NSString *name in @[@"air.log",@"midgard.log"]) {
            NSData *log = [NSData dataWithContentsOfFile:[activeWork stringByAppendingPathComponent:name]];
            if (log.length) {
                NSUInteger length = MIN(log.length,2048);
                fwrite((const uint8_t *)log.bytes+log.length-length,1,length,stderr);
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:activeWork error:NULL];
        activeWork=nil;
    }
    if (activeRequestKey) {
        NSString *key = activeRequestKey;
        activeRequestKey = nil;
        a5WriteStatus(key,@"failed",reason);
    }
    NSDictionary *request=activeDynamicRequest;
    activeDynamicRequest=nil; /* Publication errors cannot recurse on the request. */
    if(request)a5DynamicFailure(request,reason);
    exit(1);
}

static NSData *regularData(NSString *path, NSUInteger maximum)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) ||
        st.st_size <= 0 || (uint64_t)st.st_size > maximum)
        fail([@"invalid regular file: " stringByAppendingString:path]);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length != (NSUInteger)st.st_size)
        fail([@"cannot read: " stringByAppendingString:path]);
    return data;
}

static NSString *digest(NSData *data)
{
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(bytes); ++i)
        [result appendFormat:@"%02x", bytes[i]];
    return result;
}

static void writeData(NSData *data, NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) fail([@"create: " stringByAppendingString:path]);
    const uint8_t *p = data.bytes;
    NSUInteger left = data.length;
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail(@"short output write");
        p += n; left -= (NSUInteger)n;
    }
    if (fsync(fd) || close(fd)) fail(@"output sync failed");
}

static double seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) fail(@"monotonic clock unavailable");
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Diagnostic identifiers are metadata only. Bound and sanitize even inherited
 * worker context; never print argv shader constants, source, or an image path. */
static void diagnosticToken(const char *input,char result[65])
{
    unsigned i=0;
    if(input)for(;i<64&&input[i];i++){
        unsigned char c=(unsigned char)input[i];
        result[i]=((c>='a'&&c<='z')||(c>='A'&&c<='Z')||
            (c>='0'&&c<='9')||c=='_'||c=='-'||c=='.')?(char)c:'_';
    }
    if(!i){memcpy(result,"none",4);i=4;}result[i]=0;
}
/* Startup and pre-exec filesystem stalls previously had no observable phase.
 * Bound these metadata-only records independently of child progress logs. */
static void serviceCheckpoint(const char *phase,NSString *key,NSString *stage)
{
    static unsigned records;
    if(records>=256)return;
    records++;
    char request[65],kind[65];
    diagnosticToken(key.UTF8String,request);
    diagnosticToken(stage.UTF8String,kind);
    fprintf(stderr,"A5XELTE shader compiler: SERVICE phase=%s pid=%d request=%s stage=%s\n",
        phase,getpid(),request,kind);
    fflush(stderr);
}
static void workerCheckpoint(const char *phase,int argc,char **argv,int error)
{
    char request[65],stage[65];
    diagnosticToken(getenv("A5_SHADER_DIAG_REQUEST_KEY"),request);
    const char *tool=argc>3?strrchr(argv[3],'/'):NULL;
    diagnosticToken(tool?tool+1:(argc>3?argv[3]:NULL),stage);
    fprintf(stderr,"A5XELTE shader compiler: WORKER phase=%s parent_pid=%d child_pid=%d pgrp=%d request=%s stage=%s errno=%d\n",
        phase,getppid(),getpid(),getpgrp(),request,stage,error);
    fflush(stderr);
}
/* Separate exec worker inherits finite limits without changing a compositor's
 * process limits. Every child, including spirv-val, stays in its process group. */
static int worker(int argc, char **argv)
{
    if (argc < 4){workerCheckpoint("invalid-arguments",argc,argv,EINVAL);return 2;}
    NSString *path = [NSString stringWithUTF8String:argv[3]];
    if (![path hasPrefix:[installed stringByAppendingString:@"/"]]){
        workerCheckpoint("path-rejected",argc,argv,EPERM);return 2;
    }
    struct rlimit file = {8ULL * 1024 * 1024, 8ULL * 1024 * 1024};
    /* Darwin's RLIMIT_DATA includes mapped shared-cache data and can already
     * exceed500MiB before main. Enforce actual group RSS/footprint in parent. */
    if (setrlimit(RLIMIT_FSIZE, &file)){
        int error=errno;workerCheckpoint("limits-failed",argc,argv,error);return 125;
    }
    workerCheckpoint("limits-ready",argc,argv,0);
    workerCheckpoint("exec-attempt",argc,argv,0);
    execv(argv[3], &argv[3]);
    int error=errno;workerCheckpoint("exec-failed",argc,argv,error);return 126;
}
static BOOL addAccounting(uint64_t *sum,uint64_t value)
{ if(value>UINT64_MAX-*sum)return NO;*sum+=value;return YES; }

static void run(NSString *self, NSArray<NSString *> *command, NSString *log)
{
    (void)self;
#ifdef A5_SHADER_RUN_HOST_TEST
    if(a5RunTestReplacement)command=a5RunTestReplacement(command);
#endif
    NSSet *initialPending=activeDynamicRequest?a5RunnableFunctionKeys():nil;
    double start = seconds(), lastProgress = start;
    double lastDemandCheck=start,quietSince=start;
    uint64_t lastUserProgress=0;long long lastLogProgress=-1;
    char request[65],stage[65];
    diagnosticToken(activeRequestKey.UTF8String,request);
    diagnosticToken(command[0].lastPathComponent.UTF8String,stage);
    NSString *tool=command.firstObject;
    if(![tool hasPrefix:[installed stringByAppendingString:@"/"]])
        fail(@"compiler executable path rejected");
    /* The dedicated compiler daemon writes only bounded metadata, <=1MiB
     * native artifacts and <=8MiB tool logs. Apply the same former worker
     * limit here, so the actual tool and every descendant inherit it. This
     * process is separate from the compositor; its limits never change.
     * Direct spawn avoids reloading Foundation/IOKit in a --worker image
     * before the libSystem-only translator/backend can even start. */
    struct rlimit file={8ULL*1024*1024,8ULL*1024*1024};
    if(setrlimit(RLIMIT_FSIZE,&file))fail(@"compiler file limit setup failed");
    NSArray<NSString *> *all=command;
    char **args = calloc(all.count + 1, sizeof(char *));
    if (!args) fail(@"argument allocation failed");
    for (NSUInteger i = 0; i < all.count; ++i) args[i] = (char *)all[i].UTF8String;
    /* Preserve arbitrary inherited environment bytes. Replace only this private
     * diagnostic key; it carries no compiler authorization or policy input. */
    NSUInteger inherited=0;while(environ[inherited])inherited++;
    char **childEnvironment=calloc(inherited+2,sizeof(char *));
    if(!childEnvironment)fail(@"worker environment allocation failed");
    NSUInteger environmentCount=0;
    for(NSUInteger i=0;i<inherited;i++)
        if(strncmp(environ[i],"A5_SHADER_DIAG_REQUEST_KEY=",sizeof("A5_SHADER_DIAG_REQUEST_KEY=")-1))
            childEnvironment[environmentCount++]=environ[i];
    char requestEnvironment[96];snprintf(requestEnvironment,sizeof(requestEnvironment),
        "A5_SHADER_DIAG_REQUEST_KEY=%s",request);
    char *ownedEnvironment=strdup(requestEnvironment);
    if(!ownedEnvironment)fail(@"worker diagnostic allocation failed");
    childEnvironment[environmentCount]=ownedEnvironment;
    int fd = open(log.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0) fail(@"cannot create compiler log");
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    int error = posix_spawn_file_actions_init(&actions);
    if (!error) error = posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, fd);
    if (!error) error = posix_spawnattr_init(&attr);
    if (error) fail(@"spawn actions initialization failed");
    /* Tools must not inherit the daemon's flock/directory descriptors, signal
     * mask or ignored SIGCHLD. Inherited blocked signals and open locks are
     * observable process stalls, independent of shader arithmetic. There is
     * still one compiler group, the same memory bound, and no elapsed timeout. */
    sigset_t empty,defaults;sigemptyset(&empty);sigfillset(&defaults);
    sigdelset(&defaults,SIGKILL);sigdelset(&defaults,SIGSTOP);
    error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP|
        POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!error) error = posix_spawnattr_setsigmask(&attr,&empty);
    if (!error) error = posix_spawnattr_setsigdefault(&attr,&defaults);
    if (!error) error = posix_spawnattr_setpgroup(&attr, 0);
    pid_t pid = 0;
    fprintf(stderr,"A5XELTE shader compiler: SPAWN phase=begin parent_pid=%d child_pid=0 request=%s stage=%s direct=1 file_limit_bytes=8388608\n",getpid(),request,stage);
    if (!error) error = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, &attr, args, childEnvironment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(fd); free(args);free(ownedEnvironment);free(childEnvironment);
    fprintf(stderr,"A5XELTE shader compiler: SPAWN phase=complete parent_pid=%d child_pid=%d pgrp=%d request=%s stage=%s errno=%d\n",getpid(),pid,pid,request,stage,error);
    if (error) fail([NSString stringWithFormat:@"spawn error=%d", error]);
    int status = 0;BOOL execObserved=NO;
    struct rusage usage = {};
    for (;;) {
        pid_t done = wait4(pid, &status, WNOHANG, &usage);
        if (done == pid) {
            pid_t remaining[32] = {};
            int count = proc_listpgrppids(pid,remaining,sizeof(remaining));
            if (count != 0) {
                kill(-pid,SIGKILL);
                fail(@"compiler left live descendants or accounting failed");
            }
            break;
        }
        if (done < 0 && errno != EINTR) {
            int waitError=errno;
            fprintf(stderr,"A5XELTE shader compiler: WAIT_FAILED parent_pid=%d child_pid=%d request=%s stage=%s errno=%d\n",getpid(),pid,request,stage,waitError);
            kill(-pid,SIGKILL);
            fail(@"wait4 failed");
        }
        /* Probe only the exact child we spawned, never the process table. A
         * matching executable image distinguishes successful exec from a live
         * orchestration worker. A denial remains observable, not fatal. */
        int imageError=0;
        if(!execObserved){
            char image[4096]={0};
            int imageBytes=proc_pidpath?proc_pidpath(pid,image,sizeof(image)):0;
            imageError=imageBytes>0?0:(proc_pidpath?errno:ENOSYS);
            if(imageBytes>0&&!strcmp(image,command[0].fileSystemRepresentation)){
                execObserved=YES;
                fprintf(stderr,"A5XELTE shader compiler: EXEC_OBSERVED parent_pid=%d child_pid=%d pgrp=%d request=%s stage=%s\n",getpid(),pid,pid,request,stage);
            }
        }
        pid_t members[32] = {};
        int memberCount = proc_listpgrppids(pid,members,sizeof(members));
        bool invalid = memberCount < 0 || memberCount >= 32;
        uint64_t resident=0,groupResident=0,groupFootprint=0,groupUser=0,groupSystem=0;
        uint64_t childResident=0,childFootprint=0,childUser=0,childSystem=0;
        unsigned accounted=0;BOOL childAccounted=NO;
        for (int i = 0; !invalid && i < memberCount; ++i) {
            if (members[i] <= 0) continue;
            struct rusage_info_v0 info = {};
            if (proc_pid_rusage(members[i],RUSAGE_INFO_V0,(rusage_info_t *)&info)) {
                if (errno != ESRCH) invalid = true;
            } else {
                accounted++;
                invalid=!addAccounting(&resident,MAX(info.ri_resident_size,info.ri_phys_footprint))||
                    !addAccounting(&groupResident,info.ri_resident_size)||
                    !addAccounting(&groupFootprint,info.ri_phys_footprint)||
                    !addAccounting(&groupUser,info.ri_user_time)||!addAccounting(&groupSystem,info.ri_system_time);
                if(members[i]==pid){childAccounted=YES;childResident=info.ri_resident_size;
                    childFootprint=info.ri_phys_footprint;childUser=info.ri_user_time;childSystem=info.ri_system_time;}
            }
        }
        if (invalid || resident > 500ULL*1024*1024) {
            kill(-pid,SIGKILL);
            while (waitpid(pid,&status,0)<0 && errno==EINTR) {}
            fail(invalid ? @"cannot account compiler process group" : @"compiler group exceeded500MiB");
        }
        /* No elapsed compile limit: CPU/output-progressing tools continue.
         * An otherwise idle child may not monopolize a newer authenticated
         * function demand forever. Cancel only our own unstarted compiler
         * work, reap the whole group and retry its request later. */
        if(activeDynamicRequest&&childAccounted&&seconds()-lastDemandCheck>=1){
            double now=seconds();lastDemandCheck=now;
            struct stat progressStat={0};long long progressBytes=-1;
            if(!lstat(log.fileSystemRepresentation,&progressStat)&&S_ISREG(progressStat.st_mode))progressBytes=progressStat.st_size;
            if(groupUser>lastUserProgress+1000000ULL||progressBytes!=lastLogProgress){
                quietSince=now;lastUserProgress=groupUser;lastLogProgress=progressBytes;
            }
            if(now-quietSince>=10&&progressBytes==0){
                NSMutableSet *arrived=[a5RunnableFunctionKeys() mutableCopy];
                [arrived minusSet:initialPending?:[NSSet set]];
                if(arrived.count){
                    kill(-pid,SIGKILL);
                    pid_t reaped;do{reaped=waitpid(pid,&status,0);}while(reaped<0&&errno==EINTR);
                    if(reaped!=pid)fail(@"cannot reap yielded compiler child");
                    BOOL gone=NO;
                    for(unsigned attempt=0;attempt<50;attempt++){
                        pid_t remaining[32]={};int n=proc_listpgrppids(pid,remaining,sizeof(remaining));
                        if(n==0){gone=YES;break;}if(n<0||n>=32)break;usleep(20000);
                    }
                    if(!gone)fail(@"cannot prove yielded compiler group retired");
                    fprintf(stderr,"A5XELTE shader compiler: YIELD request=%s stage=%s quiet=%.1f new_functions=%lu child_reaped=1\n",
                        request,stage,now-quietSince,(unsigned long)arrived.count);
                    a5DemandYielded=YES;
                    @throw [NSException exceptionWithName:@"A5ShaderDemandYield" reason:@"new authenticated function arrived while tool made no user CPU/output progress" userInfo:nil];
                }
            }
        }
        if (seconds() - lastProgress >= 10) {
            struct stat logStat={0};long long logBytes=-1;
            if(!lstat(log.fileSystemRepresentation,&logStat)&&S_ISREG(logStat.st_mode))logBytes=logStat.st_size;
            fprintf(stderr,"A5XELTE shader compiler: RUNNING parent_pid=%d child_pid=%d pgrp=%d request=%s stage=%s wall=%.1f exec_observed=%u image_errno=%d members=%u child_accounted=%u child_user_ns=%llu child_system_ns=%llu child_resident_bytes=%llu child_footprint_bytes=%llu group_user_ns=%llu group_system_ns=%llu group_resident_bytes=%llu group_footprint_bytes=%llu resident_bytes=%llu log_bytes=%lld\n",
                getpid(),pid,pid,request,stage,seconds()-start,execObserved,imageError,accounted,childAccounted,
                (unsigned long long)childUser,(unsigned long long)childSystem,
                (unsigned long long)childResident,(unsigned long long)childFootprint,
                (unsigned long long)groupUser,(unsigned long long)groupSystem,
                (unsigned long long)groupResident,(unsigned long long)groupFootprint,
                (unsigned long long)resident,logBytes);
            lastProgress = seconds();
        }
        usleep(20000);
    }
    fprintf(stderr, "A5XELTE shader compiler: EXIT parent_pid=%d child_pid=%d pgrp=%d request=%s stage=%s status=%d exited=%u exit_code=%d signal=%d exec_observed=%u wall=%.3f cpu=%.3f peak_bytes=%ld\n",
        getpid(),pid,pid,request,stage,status,WIFEXITED(status),WIFEXITED(status)?WEXITSTATUS(status):-1,
        WIFSIGNALED(status)?WTERMSIG(status):0,execObserved,seconds()-start,
        usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+
        usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6,usage.ru_maxrss);
    if (!WIFEXITED(status) || WEXITSTATUS(status))
        fail([@"compiler/validator failed; see " stringByAppendingString:log]);
    if (usage.ru_maxrss > 500L * 1024 * 1024)
        fail(@"compiler exceeded 500 MiB; no cache published");
}

static void validateMetadata(NSDictionary *meta, NSDictionary *spec)
{
    if (![meta[@"kind"] isEqual:@"render"]) fail(@"not a render pipeline");
    NSArray *stages = meta[@"stages"];
    if (stages.count != 2 || ![stages[0][@"stage"] isEqual:@"vert"] ||
        ![stages[1][@"stage"] isEqual:@"frag"] ||
        ![stages[0][@"entry_point"] isEqual:@"main"] ||
        ![stages[1][@"entry_point"] isEqual:@"main"]) fail(@"changed shader stages");
    NSMutableArray *slots = [NSMutableArray array], *windows = [NSMutableArray array];
    for (NSArray *entry in meta[@"interface"][@"slots"]) {
        if (entry.count != 2) fail(@"invalid resource interface");
        NSDictionary *slot = entry[0], *interface = entry[1];
        [slots addObject:@[slot[@"stage"], slot[@"class"], slot[@"index"]]];
        if ([slot[@"class"] isEqual:@"Sampler"]) {
            if (![spec[@"sampled_texture"] boolValue] ||
                ![interface isEqual:@{@"Sampler":@{@"compare":@NO,@"coordinate_sensitive":@YES}}])
                fail(@"unsupported sampler interface");
        } else if ([slot[@"class"] isEqual:@"Texture"] && [spec[@"sampled_texture"] boolValue]) {
            if (![interface isEqual:@{@"Texture":@{@"texture_type":@"Type2D",@"sampled_type":@"Float",
                @"depth_compare":@NO,@"access":@{@"sample":@YES,@"read":@NO,@"write":@NO}}}])
                fail(@"unsupported sampled texture");
        } else {
            NSDictionary *resource = interface[@"Buffer"] ?: interface[@"Texture"];
            NSDictionary *access = resource[@"access"];
            if (![access[@"read"] boolValue] || [access[@"write"] boolValue] ||
                [access[@"sample"] boolValue]) fail(@"unsupported resource access");
            if (interface[@"Buffer"]) {
                id window = resource[@"window"];
                id length = [window isEqual:@"Whole"] ? @"Whole" : window[@"Bounded"][@"len"];
                [windows addObject:@[resource[@"form"][@"Descriptor"], length]];
            }
        }
    }
    if (![slots isEqual:spec[@"slots"]] || ![windows isEqual:spec[@"buffer_windows"]])
        fail(@"changed resource ABI");
    NSMutableArray *pushes = [NSMutableArray array];
    for (NSDictionary *p in meta[@"layout"][@"push_constants"])
        [pushes addObject:@[[p[@"stages"] intValue] == 1 ? @"Vertex" : @"Fragment", p[@"offset"],p[@"size"]]];
    NSDictionary *graphics = meta[@"graphics"];
    NSArray *colors = graphics[@"color_attachments"];
    if (![pushes isEqual:spec[@"push"]] || colors.count != 1 ||
        ![colors[0][@"format"] isEqual:@44] || ![colors[0][@"write_mask"] isEqual:spec[@"write_mask"]] ||
        ![graphics[@"rasterization_samples"] isEqual:@1] ||
        ![graphics[@"color_write_rules"] isEqual:@[@[@0,@0x2222]]]) fail(@"changed render/push ABI");
    if (spec[@"specialization"] &&
        ![@[stages[0][@"specialization"][@"constants"], stages[1][@"specialization"][@"constants"]]
            isEqual:spec[@"specialization"]]) fail(@"changed specialization ABI");
}

static NSDictionary *readJSON(NSString *path)
{
    id value = [NSJSONSerialization JSONObjectWithData:regularData(path, 2 * 1024 * 1024) options:0 error:NULL];
    if (![value isKindOfClass:[NSDictionary class]]) fail(@"invalid JSON dictionary");
    return value;
}

static void compilePair(NSString *self, NSString *pair)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *spec = readJSON([installed stringByAppendingPathComponent:@"pairs.json"])[pair];
    if (!spec || ![@[@"read_surf",@"downsample_4"] containsObject:pair]) fail(@"unsupported lowering profile");
    NSMutableData *keyData = [NSMutableData data];
    NSArray *inputs = @[self, sourceLibrary, [installed stringByAppendingPathComponent:@"metal2vulkan"],
        [installed stringByAppendingPathComponent:@"spirv-val"], [installed stringByAppendingPathComponent:@"midgard-compile"],
        [installed stringByAppendingPathComponent:@"profile.json"], [installed stringByAppendingPathComponent:@"pairs.json"]];
    for (NSString *path in inputs)
        [keyData appendData:[digest(regularData(path, 64 * 1024 * 1024)) dataUsingEncoding:NSUTF8StringEncoding]];
    [keyData appendData:[pair dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *key = digest(keyData);
    NSString *final = [cacheRoot stringByAppendingPathComponent:key];
    NSString *reportPath = [final stringByAppendingPathComponent:@"report.json"];
    if ([fm fileExistsAtPath:reportPath]) {
        NSDictionary *report = readJSON(reportPath);
        for (NSString *stage in @[@"vert",@"frag"]) {
            NSString *name = [@"shader." stringByAppendingFormat:@"%@.midgard",stage];
            NSData *output = regularData([final stringByAppendingPathComponent:name], 1024 * 1024);
            if (![digest(output) isEqual:report[stage][@"sha256"]])
                fail(@"cache output digest mismatch");
            NSDictionary *expected = spec[@"expected_output"][stage];
            if (expected && (![digest(output) isEqual:expected[@"sha256"]] ||
                ![@(output.length) isEqual:expected[@"bytes"]])) fail(@"cache differs from validated shader reference");
        }
        if (![report[@"key"] isEqual:key]) fail(@"cache key mismatch");
        fprintf(stderr,"A5XELTE shader compiler: CACHE HIT pair=%s key=%s\n",pair.UTF8String,key.UTF8String);
        return;
    }
    /* Bound retained versions and failed/interrupted workspaces. An operator
     * can remove old entries; never grow a cache without a finite limit. */
    NSArray *entries = [fm contentsOfDirectoryAtPath:cacheRoot error:NULL];
    if (!entries || entries.count > 64) fail(@"cache entry limit reached");
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:cacheRoot];
    for (NSString *entry in enumerator) {
        NSDictionary *attributes = [fm attributesOfItemAtPath:[cacheRoot stringByAppendingPathComponent:entry] error:NULL];
        total += [attributes[NSFileSize] unsignedLongLongValue];
        if (total > 256ULL*1024*1024) fail(@"cache size limit reached");
    }
    NSString *work = [cacheRoot stringByAppendingPathComponent:[@".work-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:work withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL])
        fail(@"cannot create private compiler workspace");
    activeWork = work;
    NSString *prefix = [work stringByAppendingPathComponent:@"shader"];
    NSString *meta = [prefix stringByAppendingString:@"-meta.json"];
    NSMutableArray *air = [NSMutableArray arrayWithArray:@[[installed stringByAppendingPathComponent:@"metal2vulkan"],
        sourceLibrary,[prefix stringByAppendingString:@".spv"],@"--function",spec[@"vertex"],@"--fragment",spec[@"fragment"],
        @"--profile",[installed stringByAppendingPathComponent:@"profile.json"],@"--color-format",@"0:BGRA8Unorm",@"--emit-meta",meta,@"--no-timeout"]];
    if (spec[@"vertex_descriptor"]) {
        NSString *descriptor = [work stringByAppendingPathComponent:@"vertex.json"];
        writeData([NSJSONSerialization dataWithJSONObject:spec[@"vertex_descriptor"] options:0 error:NULL],descriptor);
        [air addObjectsFromArray:@[@"--vertex-descriptor",descriptor]];
    }
    double start = seconds();
    setenv("METAL2VULKAN_SPIRV_VAL",[installed stringByAppendingPathComponent:@"spirv-val"].fileSystemRepresentation,1);
    run(self,air,[work stringByAppendingPathComponent:@"air.log"]);
    NSString *validationLog = [[NSString alloc] initWithData:regularData(
        [work stringByAppendingPathComponent:@"air.log"],8*1024*1024) encoding:NSUTF8StringEncoding];
    if (![validationLog containsString:@"spirv-val vulkan1.2: PASS"] ||
        [validationLog containsString:@"spirv-val: not found"]) fail(@"mandatory SPIR-V validation did not run");
    validateMetadata(readJSON(meta),spec);
    NSMutableArray *midgard = [NSMutableArray arrayWithObject:[installed stringByAppendingPathComponent:@"midgard-compile"]];
    for (NSString *suffix in @[@".vert.spv",@".frag.spv",@".vert.midgard",@".frag.midgard"])
        [midgard addObject:[prefix stringByAppendingString:suffix]];
    if ([pair isEqual:@"downsample_4"]) [midgard addObject:pair];
    run(self,midgard,[work stringByAppendingPathComponent:@"midgard.log"]);
    NSMutableDictionary *report = [@{@"key":key,@"pair":pair,@"seconds":@(seconds()-start),@"gpu_id":@"07201000"} mutableCopy];
    for (NSString *stage in @[@"vert",@"frag"]) {
        NSData *bytes = regularData([prefix stringByAppendingFormat:@".%@.midgard",stage],1024*1024);
        if (bytes.length % 16) fail(@"unaligned Midgard binary");
        NSDictionary *expected = spec[@"expected_output"][stage];
        if (expected && (![digest(bytes) isEqual:expected[@"sha256"]] ||
            ![@(bytes.length) isEqual:expected[@"bytes"]])) fail(@"compiled output differs from validated shader reference");
        report[stage] = @{@"bytes":@(bytes.length),@"sha256":digest(bytes)};
        fprintf(stderr,"A5XELTE shader compiler: pair=%s stage=%s bytes=%lu sha256=%s\n",
            pair.UTF8String,stage.UTF8String,(unsigned long)bytes.length,digest(bytes).UTF8String);
    }
    writeData([NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL],
        [work stringByAppendingPathComponent:@"report.json"]);
    /* Tool-written files need durable data too, not just report.json. */
    for (NSString *name in [fm contentsOfDirectoryAtPath:work error:NULL]) {
        NSString *path = [work stringByAppendingPathComponent:name];
        int fd = open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
        struct stat st;
        if (fd < 0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || fsync(fd) || close(fd))
            fail(@"compiler output sync failed");
    }
    int workfd = open(work.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (workfd < 0 || fsync(workfd) || close(workfd)) fail(@"workspace sync failed");
    if (rename(work.fileSystemRepresentation,final.fileSystemRepresentation)) fail(@"cache publication failed");
    activeWork = nil;
    int dir = open(cacheRoot.fileSystemRepresentation,O_RDONLY);
    if (dir < 0 || fsync(dir) || close(dir)) fail(@"cache directory sync failed");
    fprintf(stderr,"A5XELTE shader compiler: COMPILED pair=%s seconds=%.3f vert=%lu frag=%lu key=%s\n",
        pair.UTF8String,[report[@"seconds"] doubleValue],(unsigned long)[report[@"vert"][@"bytes"] unsignedLongValue],
        (unsigned long)[report[@"frag"][@"bytes"] unsignedLongValue],key.UTF8String);
}

#include "a5shader_requests.inc.m"

int main(int argc, char **argv)
{
    if(argc>1&&!strcmp(argv[1],"--worker"))workerCheckpoint("main-entry",argc,argv,0);
    @autoreleasepool {
      @try {
        if (argc > 1 && !strcmp(argv[1],"--worker")) return worker(argc,argv);
#ifdef A5_SHADER_HOST_TEST
        /* Test orchestration with genuine local OS executables. This entry is
         * excluded entirely from signed device builds and accepts no requests. */
        if(argc>=5&&!strcmp(argv[1],"--test-run")){
            activeRequestKey=[NSString stringWithUTF8String:argv[2]];
            NSMutableArray *command=[NSMutableArray new];
            for(int i=4;i<argc;i++)[command addObject:[NSString stringWithUTF8String:argv[i]]];
            run(NSBundle.mainBundle.executablePath,command,[NSString stringWithUTF8String:argv[3]]);return 0;
        }
#endif
        if (argc != 2 && argc != 3) { fprintf(stderr,"usage: %s --serve | --selftest | --pair read_surf|downsample_4\n",argv[0]); return 2; }
        NSString *self = NSBundle.mainBundle.executablePath;
        if (!NSFileManager.defaultManager) fail(@"file manager unavailable");
#ifndef A5_SHADER_HOST_TEST
        if (geteuid()) fail(@"compiler service requires root");
#endif
        if (![NSFileManager.defaultManager createDirectoryAtPath:cacheRoot withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:NULL]) fail(@"cannot create cache root");
        struct stat st;
        if (lstat(cacheRoot.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0077))
            fail(@"cache root is not a private root-owned directory");
        NSString *lock = [cacheRoot stringByAppendingPathComponent:@".lock"];
        int lockfd = open(lock.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
        if (lockfd < 0 || flock(lockfd,LOCK_EX|LOCK_NB)) fail(@"compiler cache is busy");
        fprintf(stderr,"A5XELTE shader compiler: native iOS ARM64 service start no_time_limit=1\n");
        if (argc == 2 && !strcmp(argv[1],"--serve")) {
            serviceCheckpoint("main-roots-begin",nil,nil);
            a5PrepareRequestRoots();
            serviceCheckpoint("main-roots-end",nil,nil);
            /* A synchronous Metal caller waits for these tools. Do not demote
             * the whole compiler tree to nice10 behind compositor work. */
            if (setpriority(PRIO_PROCESS,0,0))
                fprintf(stderr,"A5XELTE shader compiler: priority adjustment unavailable errno=%d\n",errno);
        }
        if (argc == 2 && !strcmp(argv[1],"--serve")) {
            /* Requests are useful during first boot. The legacy pair selftest
             * can take minutes on Cortex-A53, so it remains an explicit
             * operation instead of delaying the long-lived request worker. */
            a5Serve(self);
        } else if (argc == 2 && !strcmp(argv[1],"--selftest")) {
            for (NSString *pair in @[@"read_surf",@"downsample_4"]) {
                compilePair(self,pair);
                compilePair(self,pair);
            }
            showSuccess();
        } else if (argc == 3 && !strcmp(argv[1],"--pair")) {
            compilePair(self,[NSString stringWithUTF8String:argv[2]]);
        } else return 2;
        close(lockfd);
        fprintf(stderr,"A5XELTE shader compiler: DONE\n");
      } @catch (NSException *exception) {
        fail([@"invalid compiler metadata: " stringByAppendingString:exception.reason ?: exception.name]);
      }
    }
    return 0;
}
