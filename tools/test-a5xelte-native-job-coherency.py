#!/usr/bin/env python3
"""Run the actual AS1 job launcher with distinct CPU/GPU memory images."""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--kernel-source', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
a.output.mkdir(exist_ok=False)
s = (a.kernel_source / 'iokit/Kernel/arm/A5XELTEGPUAS1.cpp').read_text()
start = s.index('static A5G3DAS1SubmitStatus\na5g3d_as1_run_job(')
end = s.index('\nA5G3DAS1SubmitStatus\na5g3d_as1_submit(', start)
actual = s[start:end]
pre = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>
using vm_offset_t=uintptr_t;
static constexpr unsigned kAS1JobBytes=0x40000,kAS1JobVA=0x18000000;
static constexpr int kIOReturnSuccess=0,kIOMemoryIncoherentIOStore=1,kIOMemoryIncoherentIOFlush=2;
static bool failStore,failFlush,timeoutJob,faultJob,continuationObserved;
static unsigned starts,storeBytes,flushBytes,stores;
struct Memory {
 std::vector<uint8_t>cpu,gpu;
 Memory():cpu(kAS1JobBytes),gpu(kAS1JobBytes){}
 void*getBytesNoCopy(){return cpu.data();}
 int performOperation(int op,unsigned offset,unsigned bytes){
  assert(offset<=kAS1JobBytes&&bytes<=kAS1JobBytes-offset);
  if(op==1){if(failStore)return 1;memcpy(gpu.data()+offset,cpu.data()+offset,bytes);storeBytes+=bytes;++stores;}
  else {if(failFlush)return 1;memcpy(cpu.data()+offset,gpu.data()+offset,bytes);flushBytes+=bytes;}
  return 0;
 }
};
struct A5G3DAS1Context{Memory*jobs;bool installed=true,poisoned=false;uint64_t nextFence=0;};
struct A5G3DAS1Completion{uint32_t jobIRQ=0,mmuIRQ=0,gpuIRQ=0,headerStatus=0,linkedHeaderStatus=0;};
enum A5G3DAS1SubmitStatus{kAS1SubmitCompleted,kAS1SubmitInvalid,kAS1SubmitBusy,kAS1SubmitIOError,kAS1SubmitTimeout,kAS1SubmitFault};
static Memory memory;
static unsigned activeSlot,jobOffset;
static uint32_t a5g3d_as1_read(vm_offset_t,unsigned r){
 if(r==0)return 0x7200000;if(r==0x140)return 1;if(r==0x018)return 2;if(r==0x01c)return 3;
 if(r==0x1000)return timeoutJob?0:(1u<<activeSlot)|(faultJob?1u<<(activeSlot+16):0);
 return 0;
}
static void a5g3d_as1_write(vm_offset_t,unsigned r,unsigned v){
 for(unsigned slot=0;slot<2;slot++){
  unsigned base=0x1800+slot*0x80;
  if(r==base+0x40)jobOffset=v-kAS1JobVA;
  if(r==base+0x60&&v==1){
   ++starts;activeSlot=slot;
   if(slot==1){memory.gpu[0x10000]=0xa7; /* GPU-generated varying/heap */
    uint32_t complete=1;memcpy(memory.gpu.data(),&complete,4);
    memcpy(memory.gpu.data()+256,&complete,4);memcpy(memory.gpu.data()+0x1800,&complete,4);
   }else if(starts==2){assert(memory.gpu[0x10000]==0xa7);continuationObserved=true;}
   uint32_t complete=1;memcpy(memory.gpu.data()+jobOffset,&complete,4);
  }
 }
}
template<class... T>static void a5g3d_as1_fault_snapshot(T...){ }
template<class... T>static void IOLog(const char*,T...){ }
static void IODelay(unsigned){ }
static void IOSleep(unsigned){ }
static uint64_t mach_absolute_time(){static uint64_t n;return ++n;}
static void absolutetime_to_nanoseconds(uint64_t n,uint64_t*out){*out=n;}
'''
body = r'''
int main(){
 A5G3DAS1Context ctx{&memory};A5G3DAS1Completion c;uint64_t fence=0;bool started=false;
 auto reset=[&](){memset(memory.cpu.data(),0,kAS1JobBytes);memset(memory.gpu.data(),0,kAS1JobBytes);
  starts=stores=storeBytes=flushBytes=0;failStore=failFlush=timeoutJob=faultJob=continuationObserved=false;ctx.nextFence=0;};
 reset();
 assert(a5g3d_as1_run_job(&ctx,1,1,0,&c,&fence,&started,256,20,0x1800,true,false)==kAS1SubmitCompleted);
 assert(fence==1&&!started&&stores==1&&storeBytes==kAS1JobBytes&&flushBytes==96);
 assert(memory.cpu[0x10000]==0&&memory.gpu[0x10000]==0xa7); /* scratch is NOT copied back */
 assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,true)==kAS1SubmitCompleted);
 assert(fence==2&&!started&&continuationObserved&&stores==1&&flushBytes==128);
 /* Next draw replaces all bytes. No stale scratch survives the fresh store. */
 memset(memory.cpu.data(),0x5c,kAS1JobBytes);
 assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,false)==kAS1SubmitCompleted);
 assert(stores==2&&memory.gpu[0x10000]==0x5c&&flushBytes==160);
 /* Native clear stores once and reconciles its one real completion header. */
 reset();assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,false)==kAS1SubmitCompleted);
 assert(stores==1&&storeBytes==kAS1JobBytes&&flushBytes==32);
 /* Typed jobs keep the original full store/flush contract by default. */
 reset();assert(a5g3d_as1_run_job(&ctx,1,1,0,&c,&fence,&started,256,20,0x1800)==kAS1SubmitCompleted);
 assert(storeBytes==kAS1JobBytes&&flushBytes==kAS1JobBytes&&memory.cpu[0x10000]==0xa7);
 reset();failStore=true;assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,false)==kAS1SubmitIOError&&!starts);
 reset();failFlush=true;assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,false)==kAS1SubmitIOError&&started);
 reset();timeoutJob=true;assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,1,UINT32_MAX,true,false)==kAS1SubmitTimeout&&started);
 reset();faultJob=true;assert(a5g3d_as1_run_job(&ctx,1,0,512,&c,&fence,&started,0,20,UINT32_MAX,true,false)==kAS1SubmitFault&&started);
 puts("PASS actual AS1 launcher: GPU-only continuation preserves scratch, fresh draw stores full image, native headers only, typed coherency unchanged, faults never complete");
}
'''
source = a.output / 'test.cpp'
source.write_text(pre + '\n#include "'+str(a.kernel_source/'iokit/Kernel/arm/A5XELTEGPUPoll.h')+'"\n' + actual + body)
binary = a.output / 'test'
subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True)
