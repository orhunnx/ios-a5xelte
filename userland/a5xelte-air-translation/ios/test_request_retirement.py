#!/usr/bin/env python3
"""Exercise the production retirement helper and unchanged provider quota on Mac.
No device access, fake compilation, or shader substitution. Trusted status rows
are metadata fixtures; successful publications come from real worker output.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--requests', type=Path, required=True)
    parser.add_argument('--publications', type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix='a5-retirement-'))
    work.mkdir(parents=True, exist_ok=True)
    assert not list(work.iterdir()), 'fresh work directory required'
    cache, spool, published, tools = [work / p for p in ('cache', 'requests', 'published', 'tools')]
    cache.mkdir(mode=0o700)
    spool.mkdir(mode=0o1777)
    spool.chmod(0o1777)
    published.mkdir(mode=0o755)
    tools.mkdir()
    uid = os.geteuid()
    queue = spool / str(uid)
    queue.mkdir(mode=0o700)
    (queue / '.lock').touch(mode=0o600)
    statuses = cache / 'request-status'
    statuses.mkdir(mode=0o700)
    source = Path(__file__).with_name('a5shader_compile.m').resolve()
    wrapper = work / 'helper.m'
    wrapper.write_text('''#define A5_SHADER_RETIREMENT_HOST_TEST 1
#define main a5OriginalMain
#include "''' + str(source) + '''"
#undef main
static void replaceLeaf(int dir,const char *name){
 renameat(dir,name,dir,".saved-original");
 int fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL,0600);write(fd,"replacement",11);close(fd);
}
static void newLeaf(int dir,const char *name){
 int lock=openat(dir,".lock",O_RDWR);if(lock<0||flock(lock,LOCK_EX|LOCK_NB))abort();close(lock);
 int fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL,0600);write(fd,"new pending leaf",16);close(fd);
}
int main(int argc,char **argv){@autoreleasepool{
 if(argc<3)return 90;
 NSString *mode=@(argv[1]);int dir=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
 if([mode isEqual:@"recover"]){int root=open(cacheRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY);
  int claims=openat(root,"retirement-claims",O_RDONLY|O_DIRECTORY);BOOL ok=a5RetireRecoverClaim(claims,@[]);close(claims);close(root);close(dir);return ok?0:1;}
 DIR *list=fdopendir(dup(dir));struct dirent *e;unsigned done=0,rejected=0;
 while((e=readdir(list))){if(e->d_name[0]=='.')continue;
  NSData *bytes=[NSData dataWithContentsOfFile:[@(argv[2])stringByAppendingPathComponent:@(e->d_name)]];
  NSDictionary *r=a5RetireJSON(bytes);if([mode isEqual:@"failure"])a5DynamicFailure(r,@"terminal metadata test failure");
  if([mode isEqual:@"replace"])a5RetireBeforeClaim=replaceLeaf;
  if([mode isEqual:@"newleaf"])a5RetireAfterClaim=newLeaf;
  BOOL ok=a5RetireCompletedRequest(dir,e->d_name,geteuid(),bytes,r,@[]);if(ok)done++;else rejected++;
 }
 closedir(list);close(dir);printf("%u %u\\n",done,rejected);return 0;
}}
''')
    flags = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-Os', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations']
    runner = work / 'helper'
    subprocess.run(flags + ['-DA5_SHADER_HOST_TEST=1', f'-DA5_TEST_TOOLS="{tools}"', f'-DA5_TEST_CACHE="{cache}"', f'-DA5_TEST_LIBRARY="{work / "unused"}"', f'-DA5_TEST_REQUESTS="{spool}"', f'-DA5_TEST_PUBLISHED="{published}"', str(wrapper), '-framework', 'Foundation', '-o', str(runner)], check=True)
    provider_source = source.parents[2] / 'a5mali-metal' / 'A5MaliShaderCompileRequest.m'
    provider = work / 'provider.m'
    provider.write_text('#include "' + str(provider_source) + '''"
int main(int argc,char **argv){@autoreleasepool{if(argc!=2)return 90;
 NSMutableDictionary *r=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL]mutableCopy];
 [r removeObjectForKey:@"request_id"];[r removeObjectForKey:@"owner_uid"];NSError *error=nil;
 /* These quota fixtures fill the legacy pipeline lane. Construct a real typed
  * pipeline envelope; forwarding a function would test a different lane. */
 NSDictionary *v=A5MaliShaderCompileFunctionPayload(@"fixed_vert_lph_spc",MTLFunctionTypeVertex,nil,&error);
 NSDictionary *pipeline=A5MaliShaderCompilePipelinePayload([MTLRenderPipelineDescriptor new],v,r,&error);
 NSInteger result=A5MaliForwardShaderCompileRequest(pipeline,NULL,&error);printf("%ld %s\\n",(long)result,error.localizedDescription.UTF8String?:"queued");return 0;}}
''')
    producer = work / 'provider'
    subprocess.run(flags + ['-DA5_SHADER_REQUEST_HOST_TEST=1', f'-DA5_SHADER_REQUEST_TEST_ROOT="{spool}"', str(provider), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(producer)], check=True)

    def request(index, kind='pipeline'):
        body = {'owner_uid': uid, 'kind': kind, 'test_sequence': index}
        key = hashlib.sha256(canonical(body)).hexdigest()
        row = dict(body, request_id=key)
        path = queue / (key + '.request.json')
        path.write_bytes(canonical(row))
        path.chmod(0o600)
        return path, row

    def status(row, value='unsupported'):
        path = statuses / (row['request_id'] + '.json')
        path.write_bytes(canonical({'schema': 1, 'request_id': row['request_id'], 'status': value, 'reason': 'focused terminal metadata fixture'}))
        path.chmod(0o600)

    def run(mode='retire'):
        p = subprocess.run([str(runner), mode, str(queue)], capture_output=True, text=True, timeout=30, check=True)
        with (work / 'helper.log').open('a') as log:
            log.write(p.stderr)
        return tuple(map(int, p.stdout.split()))

    def pending():
        return [p for p in queue.iterdir() if not p.name.startswith('.')]

    real = [json.loads(p.read_bytes()) for p in args.requests.glob('*.request.json')]
    payload = next(r for r in real if r.get('kind') == 'function')
    payload_path = work / 'next.json'
    payload_path.write_bytes(canonical(payload))
    for i in range(64):
        request(i)
    assert run() == (0, 64) and len(pending()) == 64
    full = subprocess.check_output([str(producer), str(payload_path)], text=True)
    assert full.startswith('3 ') and len(pending()) == 64, full  # retryable Busy, no publication
    for p in pending():
        status(json.loads(p.read_bytes()))
    assert run() == (64, 0) and not pending()
    admitted = subprocess.check_output([str(producer), str(payload_path)], text=True)
    assert admitted.startswith('1 '), admitted
    for p in pending():
        p.unlink()
    # More than256 retirements; one helper process exercises all64 ring slots.
    for i in range(300):
        _, row = request(1000 + i)
        status(row)
    assert run() == (300, 0)
    archive = cache / 'completed-requests'
    assert len(list(archive.iterdir())) == 64
    assert sum(p.stat().st_size for p in archive.iterdir()) <= 8 * 1024 * 1024
    # A power loss can leave a partial private scratch after removing an old slot.
    next(archive.glob('slot-*.json')).unlink()
    (archive / '.next').write_bytes(b'{partial')
    (archive / '.next').chmod(0o600)
    _, row = request(2000)
    status(row)
    assert run() == (1, 0) and not (archive / '.next').exists()
    # Actual worker success receipts/code/reflection must all validate.
    valid_publications = 0
    for original in real:
        src = args.publications / original['request_id']
        if original.get('kind') != 'function' or not src.is_dir():
            continue
        # Exact owner_uid is part of the request digest, so host UID must match.
        assert original['owner_uid'] == uid
        shutil.copytree(src, published / src.name)
        p = queue / (src.name + '.request.json')
        p.write_bytes(canonical(original))
        p.chmod(0o600)
        assert run() == (1, 0), src.name
        valid_publications += 1
    assert valid_publications > 0
    # Private failed function status cannot strand the provider without a public failure.
    failure = dict(payload)
    failure['function'] = 'terminal_retirement_test_missing_function'
    failure.pop('request_id')
    failure['request_id'] = hashlib.sha256(canonical(failure)).hexdigest()
    p = queue / (failure['request_id'] + '.request.json')
    p.write_bytes(canonical(failure));p.chmod(0o600)
    status(failure, 'failed')
    assert run() == (0, 1) and p.exists()
    assert run('failure') == (1, 0)
    # Unsafe leaf shapes/content must remain queued.
    for case in ('mode', 'hardlink', 'symlink', 'hash'):
        p, row = request(3000)
        status(row)
        if case == 'mode': p.chmod(0o644)
        elif case == 'hardlink': os.link(p, queue / '.hardlink')
        elif case == 'symlink':
            p.rename(queue / '.target');p.symlink_to(queue / '.target')
        else: p.write_bytes(p.read_bytes() + b' ')
        assert run() == (0, 1) and p.exists(), case
        p.unlink()
        for name in ('.hardlink', '.target'):
            (queue / name).unlink(missing_ok=True)
    # Retirement is opportunistic: a producer holding the shared lock cannot
    # block compiler dispatch. Leave the original queued and retry next scan.
    p, row = request(4000);status(row)
    with (queue / '.lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = time.monotonic()
        assert run() == (0, 1) and p.exists()
        assert time.monotonic() - before < 2
        fcntl.flock(lock, fcntl.LOCK_UN)
    assert run() == (1, 0)
    # A valid claim left after a crash recovers from its authenticated name.
    p, row = request(4500);status(row)
    st = p.stat()
    claims_dir = cache / 'retirement-claims'
    claim = claims_dir / f"{row['request_id']}-{st.st_dev:x}-{st.st_ino:x}.request.json"
    p.rename(claim)
    recovered = subprocess.run([str(runner), 'recover', str(queue)], capture_output=True)
    assert recovered.returncode == 0 and not claim.exists()
    # A producer leaf published after the atomic claim remains completely untouched.
    p, row = request(4600);status(row)
    assert run('newleaf') == (1, 0) and p.read_bytes() == b'new pending leaf'
    p.unlink()
    # Corrupt genuine publication code cannot be justified by a private status.
    original = next(r for r in real if r.get('kind') == 'function' and (published / r['request_id']).is_dir())
    code = published / original['request_id'] / 'stage.midgard'
    saved = code.read_bytes();code.chmod(0o644);code.write_bytes(bytes([saved[0] ^ 0x80]) + saved[1:]);code.chmod(0o444)
    p = queue / (original['request_id'] + '.request.json');p.write_bytes(canonical(original));p.chmod(0o600)
    status(original, 'failed')
    assert run() == (0, 1) and p.exists()
    p.unlink();code.chmod(0o644);code.write_bytes(saved);code.chmod(0o444)
    # Replacement at the last race boundary is moved but never deleted; stale
    # recovery refuses it because its bytes/inode do not match the computed name.
    p, row = request(5000);status(row)
    assert run('replace') == (0, 1)
    claims = list((cache / 'retirement-claims').iterdir())
    assert len(claims) == 1 and claims[0].read_bytes() == b'replacement'
    recovered = subprocess.run([str(runner), 'recover', str(queue)], capture_output=True)
    assert recovered.returncode == 1 and claims[0].exists()
    assert (queue / '.saved-original').read_bytes() == canonical(row)
    result = {'pending64_preserved': True, 'provider_quota_unchanged': True, 'completed64_allow_next_request': True, 'retired_batch': 300, 'archive_slots': 64, 'archive_limit_bytes': 8 * 1024 * 1024, 'partial_scratch_recovered': True, 'genuine_publications_validated': valid_publications, 'public_failure_required': True, 'unsafe_files_refused': True, 'producer_lock_nonblocking_retry': True, 'replacement_claim_preserved': True, 'valid_stale_claim_recovered': True, 'new_leaf_after_claim_preserved': True, 'producer_lock_released_before_durable_claim_io': True, 'corrupt_publication_refused': True, 'device_runtime_verified': False}
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
