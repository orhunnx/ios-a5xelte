#!/usr/bin/env python3
"""Real OS child deferral plus genuine AIR/native publications; no phone writes."""
import argparse, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

def canonical(x):
    return json.dumps(x, sort_keys=True, separators=(',', ':')).encode()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ('tools', 'library', 'requests', 'reference', 'output'):
        ap.add_argument('--' + k, type=Path, required=True)
    a = ap.parse_args()
    out = a.output.resolve(); out.mkdir(mode=0o700, exist_ok=False)
    tools = out / 'tools'; shutil.copytree(a.tools, tools)
    shutil.copyfile('/bin/sleep', tools / 'sleep'); (tools / 'sleep').chmod(0o755)
    subprocess.run(['codesign', '--force', '--sign', '-', str(tools / 'sleep')], check=True)
    cache, spool, published = [out / x for x in ('cache', 'requests', 'published')]
    for p, mode in ((cache, 0o700), (spool, 0o1777), (published, 0o755)):
        p.mkdir(mode=mode); p.chmod(mode)
    queue = spool / str(os.geteuid()); queue.mkdir(mode=0o700)
    lane = queue / 'functions'; lane.mkdir(mode=0o700)
    requests = [json.loads(p.read_text()) for p in sorted(a.requests.glob('*.request.json'))]
    assert len(requests) == 2
    first, second = requests
    for r in requests:
        body = dict(r); key = body.pop('request_id')
        assert body['owner_uid'] == os.geteuid() and hashlib.sha256(canonical(body)).hexdigest() == key
    first_path = lane / (first['request_id'] + '.request.json')
    first_path.write_bytes(canonical(first)); first_path.chmod(0o600)
    source = Path(__file__).with_name('a5shader_compile.m').resolve()
    harness = out / 'harness.m'
    harness.write_text('''#define A5_SHADER_RUN_HOST_TEST 1
#define main a5OriginalMain
#include "''' + str(source) + '''"
#undef main
int main(){@autoreleasepool{
 NSString *initial=@"''' + first['request_id'] + '''";
 __block BOOL delayed=NO;
 a5RunTestReplacement=^NSArray *(NSArray *command){
  if(!delayed&&[activeRequestKey isEqual:initial]){delayed=YES;return @[ [installed stringByAppendingPathComponent:@"sleep"],@"60" ];}
  return command;
 };
 NSArray *profiles=@[readJSON([installed stringByAppendingPathComponent:@"generic603.json"])];
 a5ScanRequests(NSBundle.mainBundle.executablePath,profiles);
 assert(delayed&&!activeWork&&!activeRequestKey&&!activeDynamicRequest);
 NSString *statusPath=[[cacheRoot stringByAppendingPathComponent:@"request-status"]stringByAppendingPathComponent:[initial stringByAppendingString:@".json"]];
 NSDictionary *status=readJSON(statusPath);assert([status[@"status"]isEqual:@"deferred"]);
 NSDictionary *r=readJSON(@"''' + str(first_path) + '''");
 assert(!a5RetireTerminal(r,profiles));
 assert([NSFileManager.defaultManager fileExistsAtPath:[publishedRoot stringByAppendingPathComponent:@"''' + second['request_id'] + '''"]]);
 a5RunTestReplacement=nil;
 for(unsigned i=0;i<3&&![[NSFileManager defaultManager]fileExistsAtPath:[publishedRoot stringByAppendingPathComponent:initial]];i++)
  a5ScanRequests(NSBundle.mainBundle.executablePath,profiles);
 assert([[NSFileManager defaultManager]fileExistsAtPath:[publishedRoot stringByAppendingPathComponent:initial]]);
 assert(![[NSFileManager defaultManager]fileExistsAtPath:statusPath]);
 fprintf(stderr,"PASS stalled own child retired; newer function published; deferred original retried with real tools\\n");
}return 0;}
''')
    runner = out / 'harness'
    subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Os', '-Wall', '-Wextra', '-Werror',
                    '-Wno-deprecated-declarations', '-DA5_SHADER_HOST_TEST=1',
                    f'-DA5_TEST_TOOLS="{tools}"', f'-DA5_TEST_CACHE="{cache}"',
                    f'-DA5_TEST_REQUESTS="{spool}"', f'-DA5_TEST_PUBLISHED="{published}"',
                    f'-DA5_TEST_LIBRARY="{a.library.resolve()}"', str(harness), '-framework', 'Foundation', '-o', str(runner)], check=True)
    log = out / 'run.log'
    with log.open('wb') as f:
        child = subprocess.Popen([str(runner)], stdout=f, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while 'stage=sleep errno=0' not in log.read_text():
                assert child.poll() is None, log.read_text()
                assert time.monotonic() < deadline
                time.sleep(.1)
            # Two invalid arrivals may not cause cancellation or publication.
            bad = lane / ('0' * 64 + '.request.json')
            bad.write_bytes(canonical(second)); bad.chmod(0o600)
            external = out / 'valid-but-linked.json'; external.write_bytes(canonical(second))
            (lane / (second['request_id'] + '.request.json')).symlink_to(external)
            time.sleep(12)
            assert child.poll() is None and 'YIELD request=' not in log.read_text(), log.read_text()
            target = lane / (second['request_id'] + '.request.json'); target.unlink()
            target.write_bytes(canonical(second)); target.chmod(0o600)
            child.wait(timeout=90)
            assert child.returncode == 0, log.read_text()
        finally:
            if child.poll() is None: child.kill(); child.wait()
    text = log.read_text()
    assert text.count('YIELD request=') == 1 and 'child_reaped=1' in text
    assert text.count('STAGE PUBLISHED stage=fragment') == 2
    # Read each actual publication with the production cache loader and compare
    # the real code/semantic metadata to separately built reference outputs.
    mali = source.parents[2] / 'a5mali-metal'
    loader = out / 'cache-loader'
    subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    '-DA5_DYNAMIC_SHADER_CACHE_HOST_TEST=1', f'-DA5_DYNAMIC_SHADER_CACHE_TEST_ROOT="{published}"',
                    str(mali / 'A5MaliDynamicShaderCache.m'), str(mali / 'test_dynamic_shader_cache_publication.m'),
                    '-framework', 'Foundation', '-framework', 'Metal', '-o', str(loader)], check=True)
    for r in requests:
        key = r['request_id']; folder = published / key
        receipt = json.loads((folder / 'receipt.json').read_text())
        assert receipt['stage_compiled'] is True and receipt['compiler_abi'] == 2
        for name in ('stage.midgard', 'reflection.json'):
            assert (folder / name).read_bytes() == (a.reference / key / name).read_bytes()
        subprocess.run([str(loader), str(lane / (key + '.request.json'))], check=True)
    (out / 'proof.json').write_text(json.dumps({'own_sleep_child_yielded': True, 'invalid_and_symlink_no_yield': True,
        'deferred_not_terminal': True, 'original_retried': True, 'actual_native_publications': 2,
        'production_loader_pass': True, 'physical_worker_fix': 'pending'}, indent=2))
    print('PASS new authenticated request preempts zero-progress own child; both real shader publications verified')

if __name__ == '__main__': main()
