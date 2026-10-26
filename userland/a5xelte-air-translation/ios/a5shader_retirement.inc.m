/* SPDX-License-Identifier: MIT
 * Terminal queue bookkeeping only. This never admits a shader or pipeline.
 * A durable result precedes an atomic private claim and fresh root-owned
 * archive snapshot under the producer's per-UID lock. At most64 snapshot
 * files total<=8MiB, plus one bounded claim retained across interruption.
 */
enum { A5RetireMax=128*1024,A5RetireSlots=64 };
static BOOL a5RetireSame(const struct stat *a,const struct stat *b){
 return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_uid==b->st_uid&&
  a->st_gid==b->st_gid&&a->st_mode==b->st_mode&&a->st_nlink==b->st_nlink&&a->st_size==b->st_size&&
  a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&
  a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static BOOL a5RetireDir(int fd,mode_t mode){struct stat s;
 return fd>=0&&!fstat(fd,&s)&&S_ISDIR(s.st_mode)&&s.st_uid==geteuid()&&(s.st_mode&07777)==mode;
}
static NSData *a5RetireRead(int dir,const char *name,uid_t owner,mode_t mode,size_t maximum,struct stat *identity){
 int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;
 struct stat a,b;NSData *result=nil;
 if(!fstat(fd,&a)&&S_ISREG(a.st_mode)&&a.st_uid==owner&&(a.st_mode&07777)==mode&&
    a.st_nlink==1&&a.st_size>0&&(uint64_t)a.st_size<=maximum){
  NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)a.st_size];size_t left=data.length;uint8_t *p=data.mutableBytes;
  while(left){ssize_t n=read(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=(size_t)n;}
  uint8_t extra;if(!left&&read(fd,&extra,1)==0&&!fstat(fd,&b)&&a5RetireSame(&a,&b))result=data;
 }
 close(fd);if(result&&identity)*identity=a;return result;
}
static NSDictionary *a5RetireJSON(NSData *data){
 if(!data)return nil;id r=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
 return [r isKindOfClass:NSDictionary.class]&&[a5Canonical(r)isEqual:data]?r:nil;
}
static BOOL a5RetireRequest(NSDictionary *r,NSData *bytes,uid_t uid,NSString *key){
 if(![r isKindOfClass:NSDictionary.class]||!a5HexDigest(key)||
    ![r[@"request_id"]isEqual:key]||!a5Unsigned(r[@"owner_uid"],UINT32_MAX)||
    [r[@"owner_uid"]unsignedLongLongValue]!=uid||![a5Canonical(r)isEqual:bytes])return NO;
 NSMutableDictionary *body=[r mutableCopy];[body removeObjectForKey:@"request_id"];
 return [digest(a5Canonical(body))isEqual:key];
}
static BOOL a5RetireRecord(int dir,NSDictionary *n,NSString *file,unsigned limit){
 if(!a5ExactKeys(n,@[@"file",@"bytes",@"sha256",@"first_tag",@"work_registers",@"tls_bytes",@"wls_bytes"])||
    ![n[@"file"]isEqual:file]||!a5Unsigned(n[@"bytes"],limit)||![n[@"bytes"]unsignedIntValue]||
    ([n[@"bytes"]unsignedIntValue]&15)||!a5HexDigest(n[@"sha256"])||
    !a5Unsigned(n[@"first_tag"],15)||[n[@"first_tag"]unsignedIntValue]<2||
    [n[@"first_tag"]unsignedIntValue]==6||[n[@"first_tag"]unsignedIntValue]==7||
    !a5Unsigned(n[@"work_registers"],16)||![n[@"work_registers"]unsignedIntValue]||
    ![n[@"tls_bytes"]isEqual:@0]||![n[@"wls_bytes"]isEqual:@0])return NO;
 NSData *code=a5RetireRead(dir,file.fileSystemRepresentation,geteuid(),0444,limit,NULL);
 return code.length==[n[@"bytes"]unsignedIntegerValue]&&[digest(code)isEqual:n[@"sha256"]]&&
  (((const uint8_t*)code.bytes)[0]&15)==[n[@"first_tag"]unsignedIntValue];
}
/* Missing=0, authenticated terminal=1, corrupt/untrusted=-1. Never turn a
 * malformed publication into a terminal result by falling back to a status. */
static int a5RetirePublication(NSDictionary *request,NSArray *knownProfiles,BOOL *publicFailure){
 *publicFailure=NO;int root=open(publishedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(root<0)return errno==ENOENT?0:-1;if(!a5RetireDir(root,0755)){close(root);return -1;}
 int dir=openat(root,[request[@"request_id"]fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 int saved=errno;close(root);if(dir<0)return saved==ENOENT?0:-1;
 BOOL ok=a5RetireDir(dir,0755);NSDictionary *r=ok?a5RetireJSON(a5RetireRead(dir,"receipt.json",geteuid(),0444,128*1024,NULL)):nil;
 NSSet *members=nil;NSString *kind=request[@"kind"];
 if([kind isEqual:@"function"]&&a5DynamicRequest(request,@"11c74cc42ce5137b73d44d427f75764f886656d4ddb374422d56b609ed2762d9")){
  BOOL success=[r[@"stage_compiled"]isEqual:@YES];NSMutableDictionary *identity=[a5DynamicIdentity(request,success)mutableCopy];
  for(NSString *key in identity)if(![identity[key]isEqual:r[key]])ok=NO;
  if(success){
   NSMutableArray *keys=[identity.allKeys mutableCopy];[keys addObjectsFromArray:@[@"native",@"reflection",@"native_abi"]];
   ok=ok&&a5ExactKeys(r,keys)&&a5RetireRecord(dir,r[@"native"],@"stage.midgard",[request[@"compiler_abi"]isEqual:@2]?16384:8192);
   NSDictionary *f=r[@"reflection"];NSData *data=a5RetireRead(dir,"reflection.json",geteuid(),0444,256*1024,NULL);
   NSDictionary *reflection=a5RetireJSON(data),*context=reflection[@"compilation_context"],*abi=r[@"native_abi"],*stats=abi[@"native_info"];
   ok=ok&&a5ExactKeys(f,@[@"file",@"bytes",@"sha256"])&&[f[@"file"]isEqual:@"reflection.json"]&&
    a5Unsigned(f[@"bytes"],256*1024)&&data.length&&data.length==[f[@"bytes"]unsignedIntegerValue]&&
    [digest(data)isEqual:f[@"sha256"]]&&[context[@"requested_stage"]isEqual:request[@"stage"]]&&
    [context[@"requested_function"]isEqual:request[@"function"]]&&[context[@"selected_native_stage_only"]isEqual:@YES]&&
    [context[@"translation_indexed_constants"]isEqual:request[@"indexed_constants"]]&&
    [abi[@"schema"]isEqual:@1]&&[abi[@"stage"]isEqual:request[@"stage"]]&&
    (![request[@"compiler_abi"]isEqual:@2]||[abi[@"shader_anisotropy"]isEqual:@1])&&
    [stats[@"bytes"]isEqual:r[@"native"][@"bytes"]]&&[stats[@"first_tag"]isEqual:r[@"native"][@"first_tag"]]&&
    [stats[@"work_regs"]isEqual:r[@"native"][@"work_registers"]]&&[stats[@"tls"]isEqual:@0]&&[stats[@"wls"]isEqual:@0];
   /* Companion constants may also be present, but every requested constant
    * must be preserved exactly in the actual translation context. */
   NSArray *constants=context[@"translation_named_constants"];
   if(![constants isKindOfClass:NSArray.class])ok=NO;
   for(NSDictionary *c in request[@"named_constants"])if(![constants containsObject:c])ok=NO;
   members=[NSSet setWithArray:@[@"receipt.json",@"reflection.json",@"stage.midgard"]];
  }else{
   NSMutableArray *keys=[identity.allKeys mutableCopy];[keys addObject:@"error"];
   ok=ok&&a5ExactKeys(r,keys)&&[r[@"stage_compiled"]isEqual:@NO]&&
    [r[@"error"]isKindOfClass:NSString.class]&&[r[@"error"]length]>0&&[r[@"error"]length]<=16384;
   members=[NSSet setWithObject:@"receipt.json"];*publicFailure=ok;
  }
 }else if([kind isEqual:@"pipeline"]){
  NSDictionary *known=nil;for(NSDictionary *candidate in knownProfiles)if(a5KnownProfile(request,candidate)){known=candidate;break;}
  if(!known)ok=NO;
  else{
   NSNumber *profile=known[@"profile_id"];
   NSDictionary *expected=@{@"schema":@1,@"request_id":request[@"request_id"],@"profile_id":profile,
    @"source_library":@"quartzcore",@"metallib_sha256":known[@"metallib_sha256"],@"gpu_id":@"07201000",@"compiler_abi":@1,
    @"recipe":[NSString stringWithFormat:@"quartzcore-generic-%@",profile],@"stage_compiled":@YES,@"pipeline_compatible":@NO,
    @"descriptor_sha256":digest(a5Canonical(request[@"descriptor"])),
    @"vertex_constants_sha256":digest(a5Canonical(request[@"vertex"][@"named_constants"])),
    @"fragment_constants_sha256":digest(a5Canonical(request[@"fragment"][@"named_constants"])),
    @"vertex":a5NativeRecord(@"vertex.midgard",known[@"midgard"][@"vert"],[known[@"midgard"][@"vert"][@"native_info"][@"work_regs"]unsignedIntegerValue]),
    @"fragment":a5NativeRecord(@"fragment.midgard",known[@"midgard"][@"frag"],[known[@"midgard"][@"frag"][@"native_info"][@"work_regs"]unsignedIntegerValue])};
   ok=ok&&[r isEqual:expected]&&a5RetireRecord(dir,r[@"vertex"],@"vertex.midgard",8192)&&a5RetireRecord(dir,r[@"fragment"],@"fragment.midgard",8192);
  }
  members=[NSSet setWithArray:@[@"receipt.json",@"vertex.midgard",@"fragment.midgard"]];
 }else ok=NO;
 DIR *list=ok?fdopendir(dup(dir)):NULL;if(!list)ok=NO;
 if(list){NSMutableSet *actual=[NSMutableSet set];struct dirent *e;
  while((e=readdir(list))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
   if(actual.count>=3){ok=NO;break;}[actual addObject:[NSString stringWithUTF8String:e->d_name]];}
  closedir(list);if(![actual isEqual:members])ok=NO;
 }
 close(dir);return ok?1:-1;
}
static BOOL a5RetireTerminal(NSDictionary *request,NSArray *knownProfiles){
 BOOL failed=NO;int publication=a5RetirePublication(request,knownProfiles,&failed);
 if(publication<0)return NO;if(publication>0)return YES;
 int root=open(cacheRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(!a5RetireDir(root,0700)){if(root>=0)close(root);return NO;}
 int dir=openat(root,"request-status",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(root);
 if(!a5RetireDir(dir,0700)){if(dir>=0)close(dir);return NO;}
 NSString *name=[request[@"request_id"]stringByAppendingString:@".json"];
 NSDictionary *status=a5RetireJSON(a5RetireRead(dir,name.fileSystemRepresentation,geteuid(),0600,16384,NULL));close(dir);
 if(!a5ExactKeys(status,@[@"schema",@"request_id",@"status",@"reason"])||![status[@"schema"]isEqual:@1]||
    ![status[@"request_id"]isEqual:request[@"request_id"]]||![status[@"reason"]isKindOfClass:NSString.class])return NO;
 if([status[@"status"]isEqual:@"unsupported"])return ![request[@"kind"]isEqual:@"function"];
 /* Dynamic failed work needs its durable public failure receipt first. A
  * private failed status alone must not strand a synchronous provider waiter. */
 return [status[@"status"]isEqual:@"failed"]&&![request[@"kind"]isEqual:@"function"];
}
static BOOL a5RetireSnapshot(NSData *bytes){
 int root=open(cacheRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(!a5RetireDir(root,0700)){if(root>=0)close(root);return NO;}
 if(mkdirat(root,"completed-requests",0700)&&errno!=EEXIST){close(root);return NO;}
 int archive=openat(root,"completed-requests",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(fsync(root)){if(archive>=0)close(archive);close(root);return NO;}close(root);
 if(!a5RetireDir(archive,0700)){if(archive>=0)close(archive);return NO;}
 static BOOL audited;
 BOOL ok=YES;unsigned count=0;size_t total=0;DIR *list=fdopendir(dup(archive));if(!list)ok=NO;
 static unsigned serial;NSString *slot=[NSString stringWithFormat:@"slot-%02u.json",serial++%A5RetireSlots];
 struct dirent *entry;
 while(ok&&(entry=readdir(list))){
  if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
  NSString *name=[NSString stringWithUTF8String:entry->d_name];BOOL scratch=[name isEqual:@".next"],allowed=scratch;
  for(unsigned i=0;i<A5RetireSlots&&!allowed;++i)allowed=[name isEqual:[NSString stringWithFormat:@"slot-%02u.json",i]];
  struct stat st;
  if(!allowed||fstatat(archive,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||
     st.st_uid!=geteuid()||(st.st_mode&07777)!=0600||st.st_nlink!=1||st.st_size<0||st.st_size>A5RetireMax||
     ++count>A5RetireSlots||(total+=(size_t)st.st_size)>A5RetireSlots*A5RetireMax){ok=NO;break;}
  /* .next is exclusively service-created scratch inside a private parent.
   * A power loss may leave 0..128KiB of incomplete bytes; it is never a result. */
  if(!scratch&&(!audited||[name isEqual:slot])){
   NSData *data=a5RetireRead(archive,entry->d_name,geteuid(),0600,A5RetireMax,NULL);
   NSDictionary *r=a5RetireJSON(data);
   if(!r||!a5Unsigned(r[@"owner_uid"],UINT32_MAX)||!a5RetireRequest(r,data,[r[@"owner_uid"]unsignedIntValue],r[@"request_id"]))ok=NO;
  }
 }
 if(list)closedir(list);if(ok)audited=YES;
 if(ok){
  /* All extant files were authenticated above. Remove one old ring slot
   * before creating the staging file, keeping the physical count<=64. */
  if(unlinkat(archive,".next",0)&&errno!=ENOENT)ok=NO;
  if(ok&&unlinkat(archive,slot.fileSystemRepresentation,0)&&errno!=ENOENT)ok=NO;
  int fd=ok?openat(archive,".next",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):-1;
  if(fd<0)ok=NO;
  if(fd>=0){const uint8_t *p=bytes.bytes;size_t left=bytes.length;
   while(left){ssize_t n=write(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=(size_t)n;}
   if(left||fsync(fd))ok=NO;if(close(fd))ok=NO;
  }
  if(ok&&(renameat(archive,".next",archive,slot.fileSystemRepresentation)||fsync(archive)))ok=NO;
 }
 close(archive);return ok;
}
/* One fixed claim is separate from the 64 durable snapshots. A crash or an
 * adversarial replacement leaves it preserved, never overwrites another claim,
 * and blocks further retirement until validated recovery succeeds. The service
 * cache .lock serializes this root-private namespace across worker processes. */
static NSString *a5RetireClaimName(NSDictionary *request,const struct stat *st){
 return [NSString stringWithFormat:@"%@-%llx-%llx.request.json",request[@"request_id"],
  (unsigned long long)st->st_dev,(unsigned long long)st->st_ino];
}
static BOOL a5RetireClaim(int claims,const char *name,NSArray *profiles){
 struct stat st;if(fstatat(claims,name,&st,AT_SYMLINK_NOFOLLOW))return NO;
 NSData *bytes=a5RetireRead(claims,name,st.st_uid,0600,A5RetireMax,&st);
 NSDictionary *request=a5RetireJSON(bytes);
 if(!a5RetireRequest(request,bytes,st.st_uid,request[@"request_id"])||
    ![a5RetireClaimName(request,&st)isEqual:[NSString stringWithUTF8String:name]]||
    !a5RetireTerminal(request,profiles)||!a5RetireSnapshot(bytes))return NO;
 /* A retained UID descriptor can mutate this inode. Recheck full bytes after
  * snapshot durability; removal is only within the private claim directory. */
 NSData *again=a5RetireRead(claims,name,st.st_uid,0600,A5RetireMax,NULL);
 return [again isEqual:bytes]&&!unlinkat(claims,name,0)&&!fsync(claims);
}
static BOOL a5RetireRecoverClaim(int claims,NSArray *profiles){
 DIR *list=fdopendir(dup(claims));if(!list)return NO;
 NSString *name=nil;BOOL ok=YES;struct dirent *e;
 while((e=readdir(list))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
  if(name){ok=NO;break;}name=[NSString stringWithUTF8String:e->d_name];}
 closedir(list);return ok&&(!name||a5RetireClaim(claims,name.fileSystemRepresentation,profiles));
}
#ifdef A5_SHADER_RETIREMENT_HOST_TEST
static void (*a5RetireBeforeClaim)(int,const char *);
static void (*a5RetireAfterClaim)(int,const char *);
#endif
static BOOL a5RetireCompletedRequest(int directory,const char *name,uid_t uid,NSData *scanned,
                                    NSDictionary *request,NSArray *knownProfiles){
 NSString *key=request[@"request_id"];struct stat ds;
 if(fstat(directory,&ds)||!S_ISDIR(ds.st_mode)||ds.st_uid!=uid||(ds.st_mode&07777)!=0700||
    !a5RetireRequest(request,scanned,uid,key)||
    ![[key stringByAppendingString:@".request.json"]isEqual:[NSString stringWithUTF8String:name]]||
    !a5RetireTerminal(request,knownProfiles))return NO;
 /* Root-private preparation/recovery may fsync and read publications. Do it
  * before taking a producer lock, keeping slow I/O outside that critical section. */
 serviceCheckpoint("retire-prepare-begin",key,nil);
 int root=open(cacheRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 BOOL ok=a5RetireDir(root,0700);
 if(ok&&mkdirat(root,"retirement-claims",0700)&&errno!=EEXIST)ok=NO;
 int claims=ok?openat(root,"retirement-claims",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
 ok=ok&&a5RetireDir(claims,0700)&&!fsync(root)&&a5RetireRecoverClaim(claims,knownProfiles);
 if(root>=0)close(root);
 if(!ok){if(claims>=0)close(claims);return NO;}
 int lock=openat(directory,".lock",O_RDWR|O_NOFOLLOW|O_CLOEXEC);struct stat st;
 BOOL safe=lock>=0&&!fstat(lock,&st)&&S_ISREG(st.st_mode)&&st.st_uid==uid&&
  (st.st_mode&07777)==0600&&st.st_nlink==1&&st.st_size==0;
 if(!safe||flock(lock,LOCK_EX|LOCK_NB)){if(lock>=0)close(lock);close(claims);return NO;}
 struct stat before;NSData *bytes=ok?a5RetireRead(directory,name,uid,0600,A5RetireMax,&before):nil;
 ok=ok&&[bytes isEqual:scanned]&&a5RetireRequest(a5RetireJSON(bytes),bytes,uid,key);
#ifdef A5_SHADER_RETIREMENT_HOST_TEST
 if(ok&&a5RetireBeforeClaim)a5RetireBeforeClaim(directory,name);
#endif
 /* Plain HFS rename atomically detaches exactly one current leaf. A replacement
  * before this operation is claimed but fails identity validation and stays in
  * the private claim. A new producer leaf after it is never touched. */
 NSString *claim=ok?a5RetireClaimName(request,&before):nil;
 if(ok)ok=!renameat(directory,name,claims,claim.fileSystemRepresentation);
 /* The identity-bound leaf is now private. No durable I/O or publication
  * validation runs while the UID lock is held. The service cache lock still
  * serializes the claim; producer inode mutations are revalidated below. */
 close(lock);lock=-1;
 serviceCheckpoint("retire-unlocked",key,nil);
 if(ok)ok=!fsync(directory)&&!fsync(claims);
 #ifdef A5_SHADER_RETIREMENT_HOST_TEST
 if(ok&&a5RetireAfterClaim)a5RetireAfterClaim(directory,name);
#endif
 if(ok)ok=a5RetireClaim(claims,claim.fileSystemRepresentation,knownProfiles);
 if(claims>=0)close(claims);
 if(ok){static unsigned logs;if(logs++<64)fprintf(stderr,"A5XELTE shader compiler: RETIRED request=%s uid=%u archive_slots=64\n",key.UTF8String,uid);}
 return ok;
}
