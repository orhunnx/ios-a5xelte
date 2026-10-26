/* Internal preparation session. No synthetic hardware fence is returned. */
typedef struct {
 uint64_t handle;uint8_t *bytes;uint32_t capacity,used,uploaded;
} A5NativeUploadArena;
typedef struct {
 A5MaliClient *client;A5MaliTransport call;void *context;
 uint8_t *packet;unsigned count,accepted;int queryValid;
 A5NativeQueryRequest query;A5NativeQueryResult mapped;
 A5MaliFence last; kern_return_t error;
 A5NativeUploadArena arenas[4];unsigned arenaResets,arenaCreates,arenaWrites,arenaReuses,awaitingUploadSubmit;
 unsigned queryHits,queryBarriers,mutationBarriers,mappingBarriers,capacityFlushes;
 uint64_t queryUS,transportUS,uploadUS,submitUS;
 uint64_t stagedBytes;
} A5NativeBatchSession;
static _Thread_local A5NativeBatchSession *nativeBatch;
/* Retain at most four 1MiB idle arenas. Large transient allocations are
 * released normally; only real terminal work can enter this pool. */
typedef struct { A5NativeUploadArena arenas[4]; } A5NativeUploadPool;
static void a5NativeArenaQuarantine(A5NativeBatchSession*,uint64_t);
static kern_return_t a5NativeReleasePooled(A5MaliClient*c,A5NativeUploadArena*a){
 struct {A5MaliHeader header;uint64_t handle;} request={{1,sizeof(request),0,0},a->handle};
 size_t size=0;kern_return_t kr=c->call(c->context,9,&request,sizeof(request),NULL,&size);
 if(!kr&&size)kr=kIOReturnIOError;
 if(kr){for(unsigned i=0;i<4;i++)if(!c->nativeUploadQuarantine[i]){c->nativeUploadQuarantine[i]=a->handle;break;}}
 free(a->bytes);memset(a,0,sizeof(*a));return kr;
}
kern_return_t A5MaliEvictIdleNativeUpload(A5MaliClient*c){
 if(!c||!c->call||!c->nativeUploadPool||(nativeBatch&&nativeBatch->client==c))return kIOReturnNoResources;
 A5NativeUploadPool*p=c->nativeUploadPool;
 for(unsigned i=4;i>0;i--)if(p->arenas[i-1].handle)return a5NativeReleasePooled(c,&p->arenas[i-1]);
 return kIOReturnNoResources;
}
void A5MaliDiscardNativeUploads(A5MaliClient*c){
 if(!c||!c->nativeUploadPool||(nativeBatch&&nativeBatch->client==c))return;
 A5NativeUploadPool*p=c->nativeUploadPool;
 for(unsigned i=0;i<4;i++)if(p->arenas[i].handle)(void)a5NativeReleasePooled(c,&p->arenas[i]);
 free(p);c->nativeUploadPool=NULL;
}
static kern_return_t a5NativeArenaRelease(A5NativeBatchSession*,A5NativeUploadArena*);
static kern_return_t a5NativeArenaEvict(A5NativeBatchSession*s,unsigned first){
 for(unsigned i=4;i>first;i--){A5NativeUploadArena*a=&s->arenas[i-1];if(!a->handle)continue;
  kern_return_t kr=a5NativeArenaRelease(s,a);if(kr)return kr;
  free(a->bytes);memset(a,0,sizeof(*a));s->queryValid=0;return KERN_SUCCESS;
 }
 return kIOReturnNoResources;
}
static kern_return_t a5NativeArenaUpload(A5NativeBatchSession*s){
 for(unsigned i=0;i<4;i++){
  A5NativeUploadArena*a=&s->arenas[i];
  while(a->uploaded<a->used){
   uint32_t n=a->used-a->uploaded;if(n>A5NativeBulkWriteMax)n=A5NativeBulkWriteMax;
   size_t bytes=sizeof(A5NativeBulkWriteRequest)+n;uint8_t*packet=malloc(bytes);
   if(!packet)return kIOReturnNoMemory;
   A5NativeBulkWriteRequest h={{1,(uint32_t)bytes,0,0},a->handle,a->uploaded,n};
   memcpy(packet,&h,sizeof(h));memcpy(packet+sizeof(h),a->bytes+a->uploaded,n);
   size_t size=0;kern_return_t kr=s->call(s->context,A5NativeBulkWriteSelector,packet,bytes,NULL,&size);free(packet);
   if(kr)return kr;if(size)return kIOReturnIOError;
   a->uploaded+=n;++s->arenaWrites;
  }
 }
 return KERN_SUCCESS;
}
static kern_return_t a5NativeBatchFlush(void){
 A5NativeBatchSession*s=nativeBatch;if(!s||!s->count)return s?s->error:KERN_SUCCESS;
 unsigned count=s->count;s->count=0;
 size_t bytes=sizeof(A5NativeBatchRequest)+count*(sizeof(A5NativeSubmitRequest)+A5NativeJobBytes);
 A5NativeBatchRequest h={{1,(uint32_t)bytes,0,0},count,0};memcpy(s->packet,&h,sizeof(h));
 /* All staged writes target fresh, disjoint arena slices. They are CPU-only
  * mutations until this point; no pending GPU job was started on failure. */
 uint64_t uploadBegin=A5MaliWallUS();
 kern_return_t upload=a5NativeArenaUpload(s);s->uploadUS+=A5MaliElapsedUS(uploadBegin,A5MaliWallUS());if(upload)return s->error=upload;
 A5NativeBatchResult r={0};size_t size=sizeof(r);submissionMayBeActive=1;
 uint64_t submitBegin=A5MaliWallUS();
 kern_return_t kr=s->call(s->context,A5NativeBatchSelector,s->packet,bytes,&r,&size);
 s->submitUS+=A5MaliElapsedUS(submitBegin,A5MaliWallUS());
 if(kr){if(kr==kIOReturnNotReady||kr==kIOReturnNotFound||kr==kIOReturnNoResources||kr==kIOReturnBadArgument)submissionMayBeActive=0;return s->error=kr;}
 if(size!=sizeof(r)||r.header.version!=1||r.header.size!=sizeof(r)||r.header.reserved0||r.header.reserved1||r.count!=count||r.reserved||r.completedCount>count||r.status>5||(!r.status&&r.completedCount!=count)||(r.status&&r.completedCount==count))return s->error=kIOReturnIOError;
 uint64_t previous=s->last.fragmentFence;
 for(unsigned i=0;i<r.completedCount;i++){
  A5NativeSubmitRequest q;memcpy(&q,s->packet+sizeof(h)+i*(sizeof(q)+A5NativeJobBytes),sizeof(q));
  A5NativeSubmitResult *v=&r.items[i];
  if(v->header.version!=1||v->header.size!=sizeof(*v)||v->header.reserved0||v->header.reserved1||v->status||v->reserved||!v->fragmentFence||v->fragmentFence<=previous||(q.profileID==0?v->tilerFence!=0:(!v->tilerFence||v->tilerFence<=previous||v->fragmentFence<=v->tilerFence)))return s->error=kIOReturnIOError;
  s->last=(A5MaliFence){v->tilerFence,v->fragmentFence};previous=v->fragmentFence;
 }
 if(r.status){if(r.status==1||r.status==2)submissionMayBeActive=0;return s->error=r.status==1?kIOReturnBadArgument:r.status==2?kIOReturnBusy:r.status==4?kIOReturnTimeout:kIOReturnIOError;}
 submissionMayBeActive=0;return KERN_SUCCESS;
}
/* Reorder/subset a previously validated mapping without touching the kernel
 * mapping epoch. Unknown tokens still flush before Query17 can change PTEs.
 * Keep the full cached set so a target-only clear does not discard textures. */
static int a5NativeCachedQuery(A5NativeBatchSession*s,const A5NativeQueryRequest*q,
 A5NativeQueryResult*out){
 if(!s->queryValid)return 0;
 A5NativeQueryResult r=s->mapped;
 memset(r.surfaces,0,sizeof(r.surfaces));memset(r.buffers,0,sizeof(r.buffers));
 for(unsigned i=0;i<4;i++){
  if(q->surfaces[i]){unsigned j=0;while(j<4&&s->mapped.surfaces[j].token!=q->surfaces[i])++j;
   if(j==4)return 0;r.surfaces[i]=s->mapped.surfaces[j];}
  if(q->buffers[i]){unsigned j=0;while(j<4&&s->mapped.buffers[j].token!=q->buffers[i])++j;
   if(j==4)return 0;r.buffers[i]=s->mapped.buffers[j];}
 }
 *out=r;return 1;
}
static kern_return_t a5NativeBatchTransport(void *context,uint32_t selector,const void *in,size_t bytes,void*out,size_t*size){
 A5NativeBatchSession*s=context;if(s->error)return s->error;
 if(selector==A5NativeQuerySelector&&bytes==sizeof(s->query)&&in&&out&&size&&*size>=sizeof(s->mapped)){
  A5NativeQueryRequest q;A5NativeQueryResult r;memcpy(&q,in,sizeof(q));
  if(q.header.version==1&&q.header.size==sizeof(q)&&!q.header.reserved0&&!q.header.reserved1&&a5NativeCachedQuery(s,&q,&r)){
   ++s->queryHits;memcpy(out,&r,sizeof(r));*size=sizeof(r);return KERN_SUCCESS;
  }
 }
 if(s->count){if(selector==A5NativeQuerySelector)++s->queryBarriers;else ++s->mutationBarriers;}
 kern_return_t kr=a5NativeBatchFlush();if(kr)return kr;s->queryValid=0;
 size_t outputCapacity=size?*size:0;
 uint64_t transportBegin=A5MaliWallUS();
 kr=s->call(s->context,selector,in,bytes,out,size);
 uint64_t transportElapsed=A5MaliElapsedUS(transportBegin,A5MaliWallUS());
 if(selector==A5NativeQuerySelector)s->queryUS+=transportElapsed;else s->transportUS+=transportElapsed;
 /* An ordinary buffer allocation may need a physical slot occupied by this
  * session's idle arena. The flush above proved all submitted reads terminal.
  * Never evict a slice already handed to the current unsubmitted draw. */
 if(selector==8 && !s->awaitingUploadSubmit){
  for(unsigned retry=0;kr==kIOReturnNoResources && retry<4;retry++){
   kern_return_t evicted=a5NativeArenaEvict(s,0);if(evicted)break;
   if(size)*size=outputCapacity;
   kr=s->call(s->context,selector,in,bytes,out,size);
  }
 }
 if(!kr&&selector==A5NativeQuerySelector&&in&&bytes==sizeof(s->query)&&out&&size&&*size==sizeof(s->mapped)){
  memcpy(&s->query,in,bytes);memcpy(&s->mapped,out,sizeof(s->mapped));s->queryValid=1;
 }
 return kr;
}
kern_return_t A5MaliBeginNativeBatch(A5MaliClient*c){
 if(nativeBatch)return kIOReturnBusy;
 if(!c||!c->call||(c->gpuCommandsSupported&(A5NativeCapability|A5NativeBatchCapability))!=(A5NativeCapability|A5NativeBatchCapability))return kIOReturnUnsupported;
 for(unsigned i=0;i<4;i++)if(c->nativeUploadQuarantine[i])return kIOReturnNotReady;
 A5NativeBatchSession*s=calloc(1,sizeof(*s));if(!s)return kIOReturnNoMemory;
 s->packet=malloc(sizeof(A5NativeBatchRequest)+A5NativeBatchMax*(sizeof(A5NativeSubmitRequest)+A5NativeJobBytes));
 if(!s->packet){free(s);return kIOReturnNoMemory;}
 if(c->nativeUploadPool){
  A5NativeUploadPool*p=c->nativeUploadPool;memcpy(s->arenas,p->arenas,sizeof(s->arenas));
  for(unsigned i=0;i<4;i++)if(s->arenas[i].handle)++s->arenaReuses;
  free(p);c->nativeUploadPool=NULL;
 }
 s->client=c;s->call=c->call;s->context=c->context;nativeBatch=s;c->call=a5NativeBatchTransport;c->context=s;return KERN_SUCCESS;
}
static kern_return_t a5NativeBatchAppend(const A5NativeSubmitRequest*q,const void*jobs){
 A5NativeBatchSession*s=nativeBatch;if(s->error)return s->error;
 if(s->count){A5NativeSubmitRequest first;memcpy(&first,s->packet+sizeof(A5NativeBatchRequest),sizeof(first));
  if(s->count==A5NativeBatchMax||!A5NativeSameEpoch(&first,q)){
   if(s->count==A5NativeBatchMax)++s->capacityFlushes;else ++s->mappingBarriers;
   kern_return_t kr=a5NativeBatchFlush();if(kr)return kr;}}
 size_t offset=sizeof(A5NativeBatchRequest)+s->count*(sizeof(*q)+A5NativeJobBytes);
 memcpy(s->packet+offset,q,sizeof(*q));memcpy(s->packet+offset+sizeof(*q),jobs,A5NativeJobBytes);++s->count;s->accepted=1;s->awaitingUploadSubmit=0;return KERN_SUCCESS;
}
int A5MaliNativeBatchAccepted(A5MaliClient*c){return nativeBatch&&nativeBatch->client==c&&nativeBatch->accepted;}
static void a5NativeArenaQuarantine(A5NativeBatchSession*s,uint64_t handle){
 for(unsigned i=0;i<4;i++)if(s->client->nativeUploadQuarantine[i]==handle)return;
 for(unsigned i=0;i<4;i++)if(!s->client->nativeUploadQuarantine[i]){s->client->nativeUploadQuarantine[i]=handle;return;}
}
static kern_return_t a5NativeArenaRelease(A5NativeBatchSession*s,A5NativeUploadArena*a){
 if(!a->handle)return KERN_SUCCESS;
 struct {A5MaliHeader header;uint64_t handle;} request={{1,sizeof(request),0,0},a->handle};
 size_t size=0;kern_return_t kr=s->call(s->context,9,&request,sizeof(request),NULL,&size);
 if(!kr&&size)kr=kIOReturnIOError;
 if(kr){a5NativeArenaQuarantine(s,a->handle);return kr;}
 a->handle=0;return KERN_SUCCESS;
}
kern_return_t A5MaliStageNativeUploads(A5MaliClient*c,unsigned count,
 const A5MaliNativeUploadPart*parts,uint64_t*handles,uint32_t*offsets){
 A5NativeBatchSession*s=nativeBatch;
 if(!s||s->client!=c)return kIOReturnUnsupported;
 if(s->error)return s->error;
 if(s->awaitingUploadSubmit)return kIOReturnBusy;
 if(!count||count>4||!parts||!handles||!offsets)return kIOReturnBadArgument;
 bool reset=false,resize=false;
 for(unsigned i=0;i<count;i++){
  if(!parts[i].bytes||!parts[i].length||parts[i].length>A5NativeBufferMax)return kIOReturnBadArgument;
  A5NativeUploadArena*a=&s->arenas[i];uint32_t n=(parts[i].length+63u)&~63u;
  if(n>a->capacity)resize=true;
  if(n>a->capacity-a->used)reset=true;
 }
 if(reset||resize){
  kern_return_t kr=a5NativeBatchFlush();if(kr)return kr;
  for(unsigned i=0;i<4;i++)s->arenas[i].used=s->arenas[i].uploaded=0;
  ++s->arenaResets;
 }
 for(unsigned i=0;i<count;i++){
  A5NativeUploadArena*a=&s->arenas[i];uint32_t n=(parts[i].length+63u)&~63u;
  if(n>a->capacity){
   kern_return_t kr=a5NativeArenaRelease(s,a);if(kr)return s->error=kr;
   free(a->bytes);memset(a,0,sizeof(*a));
   uint32_t capacity=0x40000;while(capacity<n)capacity*=2;
   a->bytes=calloc(1,capacity);if(!a->bytes)return s->error=kIOReturnNoMemory;
   struct {A5MaliHeader header;uint32_t bytes,usage;} request={{1,sizeof(request),0,0},capacity,A5MaliRead|A5MaliWrite};
   struct {A5MaliHeader header;uint64_t handle;uint32_t bytes,usage;} reply={0};size_t size=sizeof(reply);
   kr=s->call(s->context,8,&request,sizeof(request),&reply,&size);
   for(unsigned retry=0;kr==kIOReturnNoResources && retry<4-count;retry++){
    kern_return_t evicted=a5NativeArenaEvict(s,count);if(evicted)break;
    size=sizeof(reply);memset(&reply,0,sizeof(reply));
    kr=s->call(s->context,8,&request,sizeof(request),&reply,&size);
   }
   if(kr)return s->error=kr;
   uint32_t slot=(uint32_t)reply.handle;
   if((reply.handle>>32)&&slot>=0x101&&slot<0x105)a->handle=reply.handle;
   if(size!=sizeof(reply)||reply.header.version!=1||reply.header.size!=sizeof(reply)||reply.header.reserved0||reply.header.reserved1||!a->handle||reply.bytes!=capacity||reply.usage!=request.usage)return s->error=kIOReturnIOError;
   a->capacity=capacity;s->queryValid=0;++s->arenaCreates;
  }
  handles[i]=a->handle;offsets[i]=a->used;
  memcpy(a->bytes+a->used,parts[i].bytes,parts[i].length);
  memset(a->bytes+a->used+parts[i].length,0,n-parts[i].length);
  a->used+=n;s->stagedBytes+=parts[i].length;
 }
 s->awaitingUploadSubmit=1;return KERN_SUCCESS;
}
kern_return_t A5MaliEndNativeBatch(A5MaliClient*c,int commit,A5MaliFence*f){
 if(f)memset(f,0,sizeof(*f));A5NativeBatchSession*s=nativeBatch;if(!s)return KERN_SUCCESS;
 if(s->client!=c)return kIOReturnBadArgument;
 kern_return_t kr=commit?a5NativeBatchFlush():s->error;
 A5NativeUploadPool*pool=(c->nativeUploadReuse&&commit&&!kr&&!submissionMayBeActive)?calloc(1,sizeof(*pool)):NULL;
 unsigned kept=0;
 for(unsigned i=0;i<4;i++){
  A5NativeUploadArena*a=&s->arenas[i];
  if(pool&&a->handle&&a->capacity<=0x100000){
   a->used=a->uploaded=0;pool->arenas[i]=*a;memset(a,0,sizeof(*a));++kept;continue;
  }
  if(a->handle){
   if(submissionMayBeActive)a5NativeArenaQuarantine(s,a->handle);
   else {kern_return_t released=a5NativeArenaRelease(s,a);if(!kr)kr=released;}
  }
  free(a->bytes);
 }
 if(kept&&!kr)c->nativeUploadPool=pool;
 else if(pool){
  /* A failed release of another arena poisons reuse for this connection. */
  for(unsigned i=0;i<4;i++)if(pool->arenas[i].handle){
   if(kr)a5NativeArenaQuarantine(s,pool->arenas[i].handle);
   free(pool->arenas[i].bytes);
  }
  free(pool);
 }
 if(s->arenaCreates||s->arenaReuses){static unsigned reports;
  if(++reports<=8||!(reports&63)||kr)fprintf(stderr,"A5XELTE Metal upload arena: creates=%u writes=%u resets=%u staged_bytes=%llu result=%x uncertain=%u reused=%u retained=%u\n",s->arenaCreates,s->arenaWrites,s->arenaResets,(unsigned long long)s->stagedBytes,(unsigned)kr,submissionMayBeActive,s->arenaReuses,c->nativeUploadPool?kept:0);
 }
 {static unsigned reports;if(++reports<=8||!(reports&63)||kr)fprintf(stderr,
  "A5XELTE Metal native grouping: queries_cached=%u query_barriers=%u mutation_barriers=%u epoch_barriers=%u capacity_flushes=%u result=%x query_us=%llu transport_us=%llu upload_us=%llu submit_us=%llu\n",
  s->queryHits,s->queryBarriers,s->mutationBarriers,s->mappingBarriers,s->capacityFlushes,(unsigned)kr,(unsigned long long)s->queryUS,(unsigned long long)s->transportUS,
  (unsigned long long)s->uploadUS,(unsigned long long)s->submitUS);}
 if(f)*f=s->last;c->call=s->call;c->context=s->context;nativeBatch=NULL;free(s->packet);free(s);return kr;
}
