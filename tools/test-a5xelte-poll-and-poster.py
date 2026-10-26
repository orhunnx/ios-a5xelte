#!/usr/bin/env python3
"""Exercise actual staged kernel functions with mock MMIO/tasks, not GPU proof."""
import argparse,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--kernel-source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
arm=a.kernel_source/'iokit/Kernel/arm'
def run(name,source):
 path=a.output/(name+'.cpp');path.write_text(source);binary=a.output/name
 subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-omit-frame-pointer',str(path),'-o',str(binary)],check=True);subprocess.run([str(binary)],check=True)
s=(arm/'A5XELTEGPUAS1.cpp').read_text();fn=s[s.index('static A5G3DAS1SubmitStatus\na5g3d_as1_run_job('):s.index('\nA5G3DAS1SubmitStatus\na5g3d_as1_submit(')]
preamble=r'''
#include <cstdint>
#include <cstring>
#include <cassert>
#include <cstdio>
using vm_offset_t=uintptr_t;
static unsigned elapsed, sleeps, spins, finishAt, faultAt, sleepScale=1;static bool hardwareStarted,busy;static uint32_t irq;
static void IOSleep(unsigned ms){elapsed+=ms*1000*sleepScale;++sleeps;}
static void IODelay(unsigned us){elapsed+=us;++spins;}
template<class... T>static void IOLog(const char*,T...){ }
static uint64_t mach_absolute_time(){return (uint64_t)elapsed*1000;}
static void absolutetime_to_nanoseconds(uint64_t n,uint64_t*out){*out=n;}
static constexpr unsigned kAS1JobBytes=262144,kAS1JobVA=0x02000000;
static constexpr int kIOMemoryIncoherentIOStore=1,kIOMemoryIncoherentIOFlush=2,kIOReturnSuccess=0;
struct BO{alignas(16) uint8_t bytes[kAS1JobBytes]={};int performOperation(int,unsigned,unsigned){return 0;}void*getBytesNoCopy(){return bytes;}};
struct A5G3DAS1Context{BO*jobs;bool installed=true,poisoned=false;uint64_t nextFence=0;};
struct A5G3DAS1Completion{uint32_t jobIRQ=0,mmuIRQ=0,gpuIRQ=0,headerStatus=0,linkedHeaderStatus=0;};
enum A5G3DAS1SubmitStatus{kAS1SubmitInvalid,kAS1SubmitBusy,kAS1SubmitFault,kAS1SubmitIOError,kAS1SubmitTimeout,kAS1SubmitCompleted};
static uint32_t a5g3d_as1_read(vm_offset_t,unsigned r){
 if(r==0)return 0x07201000;if(r==0x140)return 1;if(r==0x018)return 2;if(r==0x01c)return 2;
 if(r==0x1000){if(hardwareStarted&&finishAt&&elapsed>=finishAt)irq=2;return irq;}
 if(r==0x2000)return hardwareStarted&&faultAt&&elapsed>=faultAt?2:0;
 if(r==0x1010)return busy?2:0;return 0;
}
static void a5g3d_as1_write(vm_offset_t,unsigned r,unsigned v){if(r==0x1004)irq&=~v;if(r==0x18e0)hardwareStarted=true;}
static void a5g3d_as1_fault_snapshot(vm_offset_t,unsigned,const char*){}
'''
body=r'''
int main(){BO bo;A5G3DAS1Context c{&bo};uint64_t fence;bool started;A5G3DAS1Completion done;
 auto setup=[&](){elapsed=sleeps=spins=finishAt=faultAt=irq=0;hardwareStarted=busy=started=false;sleepScale=1;*reinterpret_cast<uint32_t*>(bo.bytes)=1;*reinterpret_cast<uint32_t*>(bo.bytes+16)=1;};
 setup();finishAt=50;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitCompleted);assert(!started&&hardwareStarted&&sleeps==0&&elapsed==50);
 setup();finishAt=800;sleepScale=12;
 assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitCompleted);
 assert(elapsed==800&&!sleeps&&!started);
 /* With an oversleeping scheduler, the old200us threshold waits12.2ms
  * for this800us event. The new2ms threshold catches the real completion. */
 setup();sleepScale=12;unsigned budget=0;A5G3DPollStats oldStats;
 while(elapsed<800)a5g3d_poll_pause(&budget,200000,&oldStats,200);
 assert(elapsed==12200&&oldStats.sleeps==1&&oldStats.sleepNS==12000000&&budget==elapsed);
 /* A terminal IRQ exactly at the timeout boundary must win over timeout. */
 setup();finishAt=2000;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16,200)==kAS1SubmitCompleted);assert(!started&&elapsed==2000);
 setup();sleepScale=12;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16,200000)==kAS1SubmitTimeout);
 assert(started&&elapsed>=2000000&&elapsed<2012000&&sleeps>0);
 setup();finishAt=5500;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitCompleted);assert(!started&&sleeps>0&&elapsed>=5500&&elapsed<6500);
 setup();assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16,200000)==kAS1SubmitTimeout);assert(started&&elapsed==2000000&&sleeps>0);
 setup();faultAt=2500;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitFault);assert(started&&sleeps>0);
 setup();busy=true;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitFault);assert(!started&&!hardwareStarted);
 setup();assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,3)==kAS1SubmitInvalid);assert(!started&&!hardwareStarted);
 setup();finishAt=5500;*reinterpret_cast<uint32_t*>(bo.bytes+16)=0;assert(a5g3d_as1_run_job(&c,0,1,0,&done,&fence,&started,16)==kAS1SubmitFault);assert(started);
 puts("PASS actual AS1 polling: 2ms bounded spin, measured oversleep charging, final IRQ sample, long yield, timeout, terminal fault, busy and invalid headers preserve uncertain ownership");}
'''
run('poll',preamble+'\n#include "'+str(arm/'A5XELTEGPUPoll.h')+'"\n'+fn+body)
s=(arm/'A5XELTEGPUUserClient.cpp').read_text();fn=s[s.index('bool\nA5XELTEGPUUserClient::posterAuthorized('):s.index('\nbool\nA5XELTEGPUUserClient::compilerAuthorized(')]
pre=r'''
#include <cstring>
#include <cassert>
#include <cstdio>
struct OSObject{int releases=0;void release(){++releases;}};static OSObject yes,no;static OSObject*const kOSBooleanTrue=&yes;
struct Process{const char*id="com.apple.PosterBoard";const char*path="/Applications/PosterBoard.app/PosterBoard";OSObject*cap=&yes;bool hasNode=true,pathFails=false;};
using proc_t=Process*;using task_t=Process*;using vnode_t=Process*;static constexpr task_t TASK_NULL=nullptr;static unsigned putsCount;
static void*get_bsdtask_info(task_t t){return t;}static const char*cs_identity_get(proc_t p){return p->id;}
static vnode_t proc_getexecutablevnode(proc_t p){return p->hasNode?p:nullptr;}
static int vn_getpath(vnode_t v,char*p,int*n){if(v->pathFails)return 1;assert(strlen(v->path)<static_cast<unsigned>(*n));strcpy(p,v->path);return 0;}
static void vnode_put(vnode_t){++putsCount;}
class A5XELTEGPUUserClient{public:static bool posterAuthorized(task_t);static OSObject*copyClientEntitlement(task_t t,const char*key){assert(!strcmp(key,"com.apple.QuartzCore.global-capture"));return t->cap;}};
'''
body=r'''
int main(){Process p;assert(A5XELTEGPUUserClient::posterAuthorized(&p));assert(putsCount==1&&yes.releases==1);
 assert(!A5XELTEGPUUserClient::posterAuthorized(nullptr));p.id=nullptr;assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p.id="other";assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p=Process{};p.path="/tmp/PosterBoard";assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p=Process{};p.hasNode=false;assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p=Process{};p.pathFails=true;assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p=Process{};p.cap=nullptr;assert(!A5XELTEGPUUserClient::posterAuthorized(&p));p.cap=&no;assert(!A5XELTEGPUUserClient::posterAuthorized(&p));assert(no.releases==1);
 puts("PASS actual PosterBoard authorization: exact signed identity/path/capability; missing and false variants denied; retained vnode/entitlement released");}
'''
run('poster',pre+fn+body)
# The helper is called solely inside the existing stock Metal boot opt-in.
init=s[s.index('bool\nA5XELTEGPUUserClient::initWithTask('):s.index('\nvoid\nA5XELTEGPUUserClient::releaseAll(')]
assert 'if (!fCompilerOnly && !allowed && PE_parse_boot_argn("a5metal"' in init
assert init.index('stockMetal == 1) {')<init.index('posterAuthorized(owningTask)')<init.index('\n    }\n    if (!allowed)')
print('PASS static boot gate containment; no physical device acceptance claim')
