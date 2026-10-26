#import "A5MaliCommandBuffer.h"
#define main batchTransportUnitMain
#include "test_native_batch.c"
#undef main
int main(void){@autoreleasepool{
 queries=batches=mutations=clockFence=fault=malformed=failTransport=0;
 A5MaliDevice*d=[[A5MaliDevice alloc]initWithTransport:transport context:&queries commandCapabilities:96 operationCapabilities:0xffffffff];assert(d);
 A5MaliCommandBuffer*b=[d newCommandBuffer];
 NSMutableData*data=[NSMutableData dataWithLength:A5NativeJobBytes];uint8_t*jobs=data.mutableBytes;memcpy(jobs+0x1000,"REAL",4);uint32_t*w=(uint32_t*)jobs;w[4]=(1u<<16)|11;w[6]=A5NativeJobVA+256;w[0x110/4]=(2u<<16)|15;w[0x114/4]=1;w[0x210/4]=(3u<<16)|19;
 A5NativeQueryRequest query={.header={1,sizeof(query),0,0},.surfaces={0x100000001,0x100000002}};
 A5NativeSubmitRequest q={.header={1,sizeof(q),0,0},.jobBytes=A5NativeJobBytes,.vertexOffset=0,.tilerOffset=256,.fragmentOffset=512,.readSurfaces=1,.writeSurfaces=2,.profileID=99,.mappingEpoch=1};memcpy(q.surfaces,query.surfaces,sizeof(q.surfaces));
 for(unsigned i=0;i<9;i++)assert([b encodeNativeWork:^kern_return_t(A5MaliClient*c,A5MaliFence*f){A5NativeQueryResult mapped;assert(!A5MaliQueryNative(c,&query,&mapped));return A5MaliSubmitNative(c,&q,data.bytes,f);}]);
 assert(!b.completedFence.fragmentFence&&!batches);NSError*error=nil;assert([b commitAndWait:&error]&&!error);assert(batches==2&&counts[0]==8&&counts[1]==1&&queries==1&&b.completedFence.fragmentFence==18);
 /* A failure before final flush discards merely prepared jobs, never reports completion. */
 b=[d newCommandBuffer];assert([b encodeNativeWork:^kern_return_t(A5MaliClient*c,A5MaliFence*f){return A5MaliSubmitNative(c,&q,data.bytes,f);}]);assert([b encodeNativeWork:^kern_return_t(A5MaliClient*c,A5MaliFence*f){(void)c;(void)f;return kIOReturnBadArgument;}]);unsigned before=batches;assert(![b commitAndWait:&error]&&batches==before&&!b.completedFence.fragmentFence);
 /* Completion is not visible on a malformed real reply. */
 b=[d newCommandBuffer];assert([b encodeNativeWork:^kern_return_t(A5MaliClient*c,A5MaliFence*f){return A5MaliSubmitNative(c,&q,data.bytes,f);}]);malformed=1;assert(![b commitAndWait:&error]&&!b.completedFence.fragmentFence&&A5MaliNativeSubmissionMayBeActive());
 puts("PASS actual command-buffer batch commit: 8+1, no early completion, preparation abort and malformed-fence failure");
}return 0;}
