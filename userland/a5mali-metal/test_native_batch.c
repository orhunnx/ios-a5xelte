/* Actual batch transport/session and exact descriptors; mock GPU fences. */
#include "A5MaliNative.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned queries,batches,mutations,counts[16],fault,malformed,failTransport;
static uint64_t clockFence;
static kern_return_t transport(void*context,uint32_t selector,const void*input,size_t bytes,void*output,size_t*size){
 (void)context;
 if(selector==A5NativeQuerySelector){queries++;const A5NativeQueryRequest*q=input;assert(bytes==sizeof(*q));A5NativeQueryResult*r=output;memset(r,0,sizeof(*r));r->header=(A5NativeHeader){1,sizeof(*r),0,0};r->flags=1;r->jobVA=A5NativeJobVA;r->jobBytes=A5NativeJobBytes;
  for(unsigned i=0;i<4;i++)if(q->surfaces[i])r->surfaces[i]=(A5NativeSpan){q->surfaces[i],0x10000000+i*0x1000000,4096,16,16,64,0x42475241,3};*size=sizeof(*r);return 0;}
 if(selector==A5NativeBatchSelector){const A5NativeBatchRequest*h=input;assert(h->count>0&&h->count<=A5NativeBatchMax&&bytes==sizeof(*h)+h->count*(sizeof(A5NativeSubmitRequest)+A5NativeJobBytes));counts[batches++]=h->count;if(failTransport)return kIOReturnNotReady;
  A5NativeBatchResult*r=output;memset(r,0,sizeof(*r));r->header=(A5NativeHeader){1,sizeof(*r),0,0};r->count=h->count;
  for(unsigned i=0;i<h->count;i++){A5NativeSubmitRequest q;memcpy(&q,(const uint8_t*)input+sizeof(*h)+i*(sizeof(q)+A5NativeJobBytes),sizeof(q));
   assert(!memcmp((const uint8_t*)input+sizeof(*h)+i*(sizeof(q)+A5NativeJobBytes)+sizeof(q)+0x1000,"REAL",4));
   if(fault&&i==1){r->status=5;break;}
   r->items[i].header=(A5NativeHeader){1,sizeof(r->items[i]),0,0};r->items[i].tilerFence=q.profileID?++clockFence:0;r->items[i].fragmentFence=++clockFence;++r->completedCount;}
  if(malformed)r->items[0].fragmentFence=0;*size=sizeof(*r);return 0;}
 assert(selector==9);mutations++;*size=0;return 0;
}
int main(void){
 A5MaliClient c={.call=transport,.gpuCommandsSupported=A5NativeCapability|A5NativeBatchCapability};
 uint8_t*jobs=calloc(1,A5NativeJobBytes);assert(jobs);memcpy(jobs+0x1000,"REAL",4);
 uint32_t*w=(uint32_t*)jobs;w[4]=(1u<<16)|11;w[6]=A5NativeJobVA+256;w[0x110/4]=(2u<<16)|15;w[0x114/4]=1;w[0x210/4]=(3u<<16)|19;
 A5NativeQueryRequest query={.header={1,sizeof(query),0,0},.surfaces={0x100000001,0x100000002}};
 A5NativeSubmitRequest q={.header={1,sizeof(q),0,0},.jobBytes=A5NativeJobBytes,.vertexOffset=0,.tilerOffset=256,.fragmentOffset=512,.readSurfaces=1,.writeSurfaces=2,.profileID=99,.mappingEpoch=1};memcpy(q.surfaces,query.surfaces,sizeof(q.surfaces));
 A5MaliFence f={0};A5NativeQueryResult mapped;
 assert(!A5MaliBeginNativeBatch(&c));for(unsigned i=0;i<11;i++){A5MaliBeginNativeSubmissionTracking();assert(!A5MaliQueryNative(&c,&query,&mapped));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));assert(A5MaliNativeBatchAccepted(&c)&&!f.fragmentFence);}
 assert(queries==1&&batches==1&&counts[0]==8);assert(!A5MaliEndNativeBatch(&c,1,&f));assert(batches==2&&counts[1]==3&&f.fragmentFence==22&&c.call==transport&&!A5MaliNativeSubmissionMayBeActive());
 /* Different logical ordering/subsets of resident tokens must not end the
  * group or lose the full cached map. Actual VAs follow tokens, not positions. */
 unsigned queryBefore=queries,batchBefore=batches;
 assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliQueryNative(&c,&query,&mapped));
 assert(!A5MaliSubmitNative(&c,&q,jobs,&f));
 A5NativeQueryRequest subset=query;subset.surfaces[0]=query.surfaces[1];subset.surfaces[1]=0;
 assert(!A5MaliQueryNative(&c,&subset,&mapped)&&mapped.surfaces[0].gpuVA==0x11000000&&!mapped.surfaces[1].token);
 A5NativeSubmitRequest sub=q;sub.surfaces[0]=subset.surfaces[0];sub.surfaces[1]=0;sub.readSurfaces=0;sub.writeSurfaces=1;
 assert(!A5MaliSubmitNative(&c,&sub,jobs,&f));
 A5NativeQueryRequest reverse=query;reverse.surfaces[0]=query.surfaces[1];reverse.surfaces[1]=query.surfaces[0];
 assert(!A5MaliQueryNative(&c,&reverse,&mapped)&&mapped.surfaces[1].gpuVA==0x10000000);
 assert(!A5MaliQueryNative(&c,&query,&mapped));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));
 assert(queries==queryBefore+1&&batches==batchBefore);
 assert(!A5MaliEndNativeBatch(&c,1,&f)&&batches==batchBefore+1&&counts[batchBefore]==3);
 clockFence=22;
 assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));unsigned before=batches;size_t z=0;assert(!c.call(c.context,9,NULL,0,NULL,&z));assert(batches==before+1&&mutations==1);assert(!A5MaliEndNativeBatch(&c,1,&f)&&f.fragmentFence==24);
 assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));before=batches;query.surfaces[0]++;assert(!A5MaliQueryNative(&c,&query,&mapped));assert(batches==before+1);assert(!A5MaliEndNativeBatch(&c,1,&f));
 assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));before=batches;assert(!A5MaliEndNativeBatch(&c,0,&f)&&batches==before&&!f.fragmentFence); /* abort never starts pending jobs */
 assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));fault=1;assert(A5MaliEndNativeBatch(&c,1,&f)==kIOReturnIOError&&A5MaliNativeSubmissionMayBeActive());fault=0;
 A5MaliBeginNativeSubmissionTracking();assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));malformed=1;assert(A5MaliEndNativeBatch(&c,1,&f)==kIOReturnIOError&&A5MaliNativeSubmissionMayBeActive());malformed=0;
 A5MaliBeginNativeSubmissionTracking();assert(!A5MaliBeginNativeBatch(&c));assert(!A5MaliSubmitNative(&c,&q,jobs,&f));failTransport=1;assert(A5MaliEndNativeBatch(&c,1,&f)==kIOReturnNotReady&&!A5MaliNativeSubmissionMayBeActive());
 c.gpuCommandsSupported=A5NativeCapability;assert(A5MaliBeginNativeBatch(&c)==kIOReturnUnsupported&&c.call==transport);
 free(jobs);puts("PASS actual native batch session: 8+3 grouping, cached query, mutation/mapping barriers, abort, real fences, fault/malformed quarantine and legacy fallback");return 0;
}
