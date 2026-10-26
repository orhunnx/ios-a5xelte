#!/usr/bin/env python3
"""Exercise actual staged batch preflight/dispatch with mock MMIO terminal jobs."""
import argparse,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--kernel-source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(exist_ok=False);arm=a.kernel_source/'iokit/Kernel/arm'
s=(arm/'A5XELTENativeClient.inc').read_text();copy=s[s.index('static IOReturn a5gpu_copy_native_input'):s.index('/* All methods run')];method=s[s.index('IOReturn A5XELTEGPUUserClient::nativeBatch('):]
pre=r'''
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <cstdio>
#include <vector>
#include <string>
#include "NATIVE_ABI"
using IOReturn=int;using IOByteCount=size_t;using vm_offset_t=uintptr_t;using A5GPUClientHeader=A5NativeHeader;
static constexpr int kIOReturnSuccess=0,kIOReturnUnsupported=1,kIOReturnBadArgument=2,kIOReturnNoMemory=3,kIOReturnUnderrun=4,kIOReturnNotReady=5,kIOReturnNotFound=6;
static constexpr int kIOMemoryIncoherentIOStore=1,kIOMemoryIncoherentIOFlush=2,kIODirectionOut=0;
static uint64_t mach_absolute_time(){static uint64_t n;return ++n;}
static void absolutetime_to_nanoseconds(uint64_t n,uint64_t*out){*out=n;}
static unsigned jobsRun,failAt,failStatus,epochWrites,acquires,acquireFailAt;static uint64_t nextFence;static bool poisoned;
struct IOLock{bool held=false;};static IOLock gpuLock,clientLock;static IOLock*a5g3d_as1_lock(){return &gpuLock;}
static void IOLockLock(IOLock*l){assert(!l->held);l->held=true;}static void IOLockUnlock(IOLock*l){assert(l->held);l->held=false;}
struct IOMemoryDescriptor{std::vector<uint8_t>bytes;unsigned stores=0,flushes=0,wires=0;bool badFlush=false;
 explicit IOMemoryDescriptor(size_t n=4096):bytes(n){} size_t getLength(){return bytes.size();}void*getBytesNoCopy(){return bytes.data();}
 int prepare(int){++wires;return 0;}int complete(int){assert(wires);--wires;return 0;}
 size_t readBytes(size_t o,void*p,size_t n){memcpy(p,bytes.data()+o,n);return n;}
 int performOperation(int op,size_t,size_t){if(op==1)++stores;else ++flushes;return op==2&&badFlush?1:0;}};
using IOBufferMemoryDescriptor=IOMemoryDescriptor;
struct A5NativePhysicalUse{uint32_t reads,writes,buffers;};
struct SweetSurface{IOMemoryDescriptor*memory;unsigned width=16,height=16,bytesPerRow=64,pixelFormat=0x42475241,bytesPerElement=4,id=1;uintptr_t kernelAddress(){return (uintptr_t)memory->getBytesNoCopy();}};
static void sweet_surface_did_write(SweetSurface*){++epochWrites;}
static constexpr unsigned kAS1Base=0x10000000,kAS1Window=0x1000000,kAS1BufferBase=0x20000000,kAS1BufferWindow=0x800000,kAS1BGRA=0x42475241,kAS1JobVA=A5NativeJobVA;
struct A5G3DAS1Context{IOMemoryDescriptor*jobs;SweetSurface*surface[4]={};IOMemoryDescriptor*buffer[4]={};unsigned mappedBytes[4]={},bufferBytes[4]={};bool installed=true,poisoned=false;uint64_t completedFence=0;};static A5G3DAS1Context*gAS1Owner;
enum A5G3DAS1SubmitStatus{kAS1SubmitCompleted,kAS1SubmitInvalid,kAS1SubmitBusy,kAS1SubmitIOError,kAS1SubmitTimeout,kAS1SubmitFault};
struct A5G3DAS1Completion{uint32_t headerStatus=1,mmuIRQ=0;uint64_t tilerFence=0,fragmentFence=0;};
struct IOService{void release(){}};static IOService owner;
static int PE_parse_boot_argn(const char*,int*p,size_t){*p=1;return 1;}
static bool a5g3d_queue_acquire_runtime_wait(IOService**o,uint64_t*t,IOBufferMemoryDescriptor**b,vm_offset_t*g){if(++acquires==acquireFailAt)return false;*o=&owner;*t=1;*b=gAS1Owner->jobs;*g=1;return true;}
static bool a5g3d_queue_release(IOService*,uint64_t){return true;}
static void a5g3d_queue_poison(IOService*,uint64_t){poisoned=true;}
static uint32_t a5g3d_as1_read(vm_offset_t,unsigned r){return r==0x100?3:r==0x140?1:0;}
static A5G3DAS1SubmitStatus a5g3d_as1_run_job(A5G3DAS1Context*,vm_offset_t,unsigned,uint32_t,A5G3DAS1Completion*,uint64_t*f,bool*started,uint32_t,unsigned,uint32_t=UINT32_MAX,bool=false,bool=false){
 assert(gpuLock.held);++jobsRun;*started=true;if(failAt==jobsRun)return static_cast<A5G3DAS1SubmitStatus>(failStatus);*f=++nextFence;*started=false;return kAS1SubmitCompleted;}
template<class... T>static void IOLog(const char*,T...){ }
#include "NATIVE_QUEUE"
static void*IOMallocData(size_t n){return malloc(n);}static void IOFreeData(void*p,size_t){free(p);}
static bool a5gpu_valid_header(const A5GPUClientHeader*h,uint32_t bytes){return h&&h->version==1&&h->size==bytes&&!h->reserved0&&!h->reserved1;}
struct IOExternalMethodArguments{unsigned scalarInputCount=0,scalarOutputCount=0;void*structureOutput=nullptr;void*structureOutputDescriptor=nullptr;size_t structureOutputSize=0;IOMemoryDescriptor*structureInputDescriptor=nullptr;const void*structureInput=nullptr;size_t structureInputSize=0;};
class A5XELTEGPUUserClient{public:IOLock*fLock=&clientLock;A5G3DAS1Context*fAS1=nullptr;uint32_t fMappingEpoch=1;IOReturn nativeBatch(IOExternalMethodArguments*);
 IOReturn nativeTokensLocked(const uint64_t*s,const uint64_t*,void*,uint32_t r,uint32_t w,uint32_t b,uint32_t*reads,uint32_t*writes,uint32_t*buffers){for(unsigned i=0;i<4;i++)if((r|w)&(1u<<i))if(s[i]!=0x100000001&&s[i]!=0x100000002)return kIOReturnNotFound;*reads=r;*writes=w;*buffers=b;return 0;}};
'''.replace('NATIVE_ABI',str(arm/'A5XELTENativeABI.h')).replace('NATIVE_QUEUE',str(arm/'A5XELTENativeQueue.inc'))
body=r'''
int main(){IOMemoryDescriptor source,target,job(A5NativeJobBytes);SweetSurface src{&source},dst{&target};A5G3DAS1Context ctx{&job};ctx.surface[0]=&src;ctx.surface[1]=&dst;ctx.mappedBytes[0]=ctx.mappedBytes[1]=4096;gAS1Owner=&ctx;
 A5XELTEGPUUserClient client;client.fAS1=&ctx;
 const unsigned stride=sizeof(A5NativeSubmitRequest)+A5NativeJobBytes;
 std::vector<uint8_t>packet(sizeof(A5NativeBatchRequest)+A5NativeBatchMax*stride);
 auto entry=[&](unsigned i){return packet.data()+sizeof(A5NativeBatchRequest)+i*stride;};
 auto setup=[&](){memset(packet.data(),0,packet.size());A5NativeBatchRequest header={{1,(unsigned)packet.size(),0,0},A5NativeBatchMax,0};memcpy(packet.data(),&header,sizeof(header));
  for(unsigned i=0;i<A5NativeBatchMax;i++){A5NativeSubmitRequest q={};q.header={1,sizeof(q),0,0};q.jobBytes=A5NativeJobBytes;q.vertexOffset=0;q.tilerOffset=256;q.fragmentOffset=512;q.readSurfaces=1;q.writeSurfaces=2;q.profileID=99;q.mappingEpoch=1;q.surfaces[0]=0x100000001;q.surfaces[1]=0x100000002;memcpy(entry(i),&q,sizeof(q));uint32_t*w=(uint32_t*)(entry(i)+sizeof(q));w[4]=(1u<<16)|11;w[6]=A5NativeJobVA+256;w[0x110/4]=(2u<<16)|15;w[0x114/4]=1;w[0x210/4]=(3u<<16)|19;}
  jobsRun=failAt=failStatus=epochWrites=acquires=acquireFailAt=0;nextFence=0;poisoned=ctx.poisoned=false;source.stores=source.flushes=target.stores=target.flushes=0;};
 A5NativeBatchResult result;IOExternalMethodArguments args;args.structureInput=packet.data();args.structureInputSize=packet.size();args.structureOutput=&result;args.structureOutputSize=sizeof(result);
 setup();assert(client.nativeBatch(&args)==0);assert(result.completedCount==A5NativeBatchMax&&result.status==0&&jobsRun==2*A5NativeBatchMax&&nextFence==2*A5NativeBatchMax);assert(source.stores==1&&target.stores==1&&target.flushes==1&&!source.flushes&&epochWrites==A5NativeBatchMax);for(unsigned i=0;i<A5NativeBatchMax;i++)assert(result.items[i].fragmentFence==2*(i+1));
 setup();((A5NativeSubmitRequest*)entry(2))->mappingEpoch=2;assert(client.nativeBatch(&args)==kIOReturnBadArgument&&!jobsRun);
 setup();for(unsigned i=0;i<A5NativeBatchMax;i++)((A5NativeSubmitRequest*)entry(i))->mappingEpoch=2;assert(client.nativeBatch(&args)==kIOReturnNotReady&&!jobsRun);
 setup();((A5NativeSubmitRequest*)entry(2))->surfaces[0]=0x200000001;assert(client.nativeBatch(&args)==kIOReturnNotFound&&!jobsRun);
 setup();{auto*q=(A5NativeSubmitRequest*)entry(2);q->surfaces[0]=0x100000002;q->surfaces[1]=0x100000001;}assert(!client.nativeBatch(&args)&&result.completedCount==A5NativeBatchMax);
 setup();{auto*q=(A5NativeSubmitRequest*)entry(2);q->surfaces[0]=0;q->readSurfaces=0;}assert(!client.nativeBatch(&args)&&result.completedCount==A5NativeBatchMax);
 setup();((A5NativeSubmitRequest*)entry(2))->header.reserved0=1;assert(client.nativeBatch(&args)==kIOReturnBadArgument&&!jobsRun);
 setup();((uint32_t*)(entry(2)+sizeof(A5NativeSubmitRequest)))[6]=0;assert(client.nativeBatch(&args)==kIOReturnBadArgument&&!jobsRun);
 setup();((A5NativeBatchRequest*)packet.data())->count=A5NativeBatchMax+1;assert(client.nativeBatch(&args)==kIOReturnBadArgument&&!jobsRun);
 setup();acquireFailAt=2;assert(!client.nativeBatch(&args)&&result.status==2&&result.completedCount==1&&jobsRun==2&&!ctx.poisoned&&target.flushes==1);
 setup();failAt=3;failStatus=kAS1SubmitFault;assert(!client.nativeBatch(&args)&&result.status==5&&result.completedCount==1&&jobsRun==3&&ctx.poisoned&&poisoned&&!target.flushes);
 setup();IOMemoryDescriptor snapshot(packet.size());snapshot.bytes=packet;args.structureInput=nullptr;args.structureInputSize=0;args.structureInputDescriptor=&snapshot;assert(!client.nativeBatch(&args)&&!snapshot.wires&&result.completedCount==A5NativeBatchMax);
 puts("PASS actual kernel batch: all-item preflight before GPU, eight real ordered fences, single image clean/flush, direct-write epochs, fault poisoning and wired descriptor snapshot");}
'''
source=a.output/'test.cpp';source.write_text(pre+copy+method+body);binary=a.output/'test';subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-Wno-unused-function',str(source),'-o',str(binary)],check=True);subprocess.run([str(binary)],check=True)
