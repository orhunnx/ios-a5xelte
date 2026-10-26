/* SPDX-License-Identifier: MIT */
#include "A5MaliNative.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include "A5MaliTiming.h"
_Static_assert(sizeof(A5NativeQueryRequest)==80,"native query ABI");
_Static_assert(sizeof(A5NativeQueryResult)==352,"native spans ABI");
_Static_assert(sizeof(A5NativeSubmitRequest)==120,"native submit ABI");
_Static_assert(sizeof(A5NativeSubmitResult)==40,"native fences ABI");
_Static_assert(sizeof(A5NativeBatchRequest)==24&&sizeof(A5NativeBatchResult)==352,"native batch ABI");
static _Thread_local int submissionMayBeActive;
#include "A5MaliNativeBatch.inc"

void A5MaliBeginNativeSubmissionTracking(void){if(!nativeBatch||!nativeBatch->error)submissionMayBeActive=0;if(nativeBatch)nativeBatch->accepted=0;}
int A5MaliNativeSubmissionMayBeActive(void){return submissionMayBeActive;}
static int valid(A5NativeHeader h,size_t bytes,size_t actual)
{ return h.version==1 && h.size==bytes && actual==bytes && !h.reserved0 && !h.reserved1; }
static kern_return_t nativeCall(A5MaliClient *c,uint32_t selector,
 const void *in,size_t count,void *out,size_t *size)
{
 if (!c || !(c->gpuCommandsSupported&A5NativeCapability) || !c->call)
  return kIOReturnUnsupported;
 return c->call(c->context,selector,in,count,out,size);
}
static unsigned queryDiagnosticBegin(const A5NativeQueryRequest *q)
{
 static atomic_uint count;
 unsigned value=atomic_load_explicit(&count,memory_order_relaxed);
 do {if(value>=64)return 0;} while(!atomic_compare_exchange_weak_explicit(&count,&value,value+1,
  memory_order_relaxed,memory_order_relaxed));
 unsigned surfaces=0,buffers=0;
 if(q)for(unsigned i=0;i<A5NativeSlots;++i){surfaces+=q->surfaces[i]!=0;buffers+=q->buffers[i]!=0;}
 fprintf(stderr,"A5XELTE Metal Query17: receipt=%u phase=begin surfaces=%u buffers=%u\n",value+1,surfaces,buffers);
 return value+1;
}
static kern_return_t queryDiagnosticEnd(unsigned receipt,const char *phase,kern_return_t status)
{
 if(receipt)fprintf(stderr,"A5XELTE Metal Query17: receipt=%u phase=%s result=%x\n",receipt,phase,(unsigned)status);
 return status;
}
kern_return_t A5MaliQueryNative(A5MaliClient *c,const A5NativeQueryRequest *q,
 A5NativeQueryResult *r)
{
 int requestValid=q && r && valid(q->header,sizeof(*q),sizeof(*q));
 unsigned diagnostic=queryDiagnosticBegin(requestValid?q:NULL);
 if (!requestValid)
  return queryDiagnosticEnd(diagnostic,"request-validation",kIOReturnBadArgument);
 A5NativeQueryResult result={0}; size_t size=sizeof(result);
 kern_return_t kr=nativeCall(c,A5NativeQuerySelector,q,sizeof(*q),&result,&size);
 if (kr) return queryDiagnosticEnd(diagnostic,"transport",kr);
 if (!valid(result.header,sizeof(result),size) || !result.flags ||
     result.jobVA!=A5NativeJobVA || result.jobBytes!=A5NativeJobBytes)
  return queryDiagnosticEnd(diagnostic,"reply-header",kIOReturnBadArgument);
 for (unsigned i=0;i<A5NativeSlots;i++) {
  if (result.surfaces[i].token!=q->surfaces[i] || result.buffers[i].token!=q->buffers[i])
   return queryDiagnosticEnd(diagnostic,"reply-identity",kIOReturnBadArgument);
  if (q->surfaces[i] && (!result.surfaces[i].gpuVA || !result.surfaces[i].bytes))
   return queryDiagnosticEnd(diagnostic,"reply-surface-span",kIOReturnBadArgument);
  if (q->buffers[i] && (!result.buffers[i].gpuVA || !result.buffers[i].bytes))
   return queryDiagnosticEnd(diagnostic,"reply-buffer-span",kIOReturnBadArgument);
 }
 *r=result; return queryDiagnosticEnd(diagnostic,"complete",KERN_SUCCESS);
}
kern_return_t A5MaliSubmitNative(A5MaliClient *c,const A5NativeSubmitRequest *q,
 const void *jobs,A5MaliFence *f)
{
 if (f) memset(f,0,sizeof(*f));
 if (!q || !jobs || !f || q->jobBytes!=A5NativeJobBytes ||
   !valid(q->header,sizeof(*q),sizeof(*q)) || q->reserved || !q->mappingEpoch ||
   (q->readSurfaces|q->writeSurfaces|q->readBuffers)&~15u || !q->writeSurfaces ||
   q->fragmentOffset>=q->jobBytes-256 || (q->fragmentOffset&15u) ||
   (q->profileID==0 ? (q->vertexOffset!=UINT32_MAX || q->tilerOffset!=UINT32_MAX) :
    (q->vertexOffset>=q->jobBytes-256 || q->tilerOffset>=q->jobBytes-256 ||
     ((q->vertexOffset|q->tilerOffset)&15u))))
  return kIOReturnBadArgument;
 if(A5NativeCheckJobChain(jobs,q->jobBytes,A5NativeJobVA,q->vertexOffset,
    q->tilerOffset,q->fragmentOffset,q->profileID==0)<0)return kIOReturnBadArgument;
 if(nativeBatch && nativeBatch->client==c)return a5NativeBatchAppend(q,jobs);
 size_t count=sizeof(*q)+q->jobBytes;
 uint8_t *input=malloc(count); if (!input) return kIOReturnNoMemory;
 memcpy(input,q,sizeof(*q)); memcpy(input+sizeof(*q),jobs,q->jobBytes);
 A5NativeSubmitResult r={0}; size_t size=sizeof(r);
 if(!c || !(c->gpuCommandsSupported&A5NativeCapability) || !c->call){free(input);return kIOReturnUnsupported;}
 submissionMayBeActive=1;
 kern_return_t kr=nativeCall(c,A5NativeSubmitSelector,input,count,&r,&size);
 free(input); if (kr) {
  /* Selector18 returns these exact resource/epoch errors before dispatch.
   * Started jobs report through r.status instead. Do not quarantine every
   * retained surface for a stale mapping epoch or a preflight resource miss.
   * Transport errors, timeouts and malformed replies remain uncertain. */
  if(kr==kIOReturnNotReady || kr==kIOReturnNotFound || kr==kIOReturnNoResources)
   submissionMayBeActive=0;
  return kr;
 }
 if (!valid(r.header,sizeof(r),size) || r.reserved || r.status>5)
  return kIOReturnBadArgument;
 if (r.status) {
  /* Protocol states1/2 reject before the kernel starts a job. Fault/timeout
   * states keep the address space and pages pinned, so remain uncertain. */
  if(r.status==1 || r.status==2)submissionMayBeActive=0;
  return r.status==1?kIOReturnBadArgument:r.status==2?kIOReturnBusy:
   r.status==4?kIOReturnTimeout:kIOReturnIOError;
 }
 if (!r.fragmentFence || (q->profileID==0 ? r.tilerFence!=0 :
     (!r.tilerFence || r.fragmentFence<=r.tilerFence))) return kIOReturnIOError;
 f->tilerFence=r.tilerFence; f->fragmentFence=r.fragmentFence;
 submissionMayBeActive=0;return KERN_SUCCESS;
}
