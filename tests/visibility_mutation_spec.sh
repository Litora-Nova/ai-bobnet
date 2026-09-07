#!/usr/bin/env bash
# Prove the eight visibility gate survivors are killed by focused behavioral pins.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import pathlib,shutil,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]);passed=failed=0

def check(label,condition):
    global passed,failed
    if condition:passed+=1;print('ok - '+label)
    else:failed+=1;print('FAIL - '+label)

mutants=[
 ('stream-lock','locks','bin/project','  aib_attempts_fold "$AIB_EVENT_ROOT/$uid/main.events"',
  '  exec {reader_lock}>>"$AIB_EVENT_ROOT/$uid/main.events.lock"; flock -x "$reader_lock"\n  aib_attempts_fold "$AIB_EVENT_ROOT/$uid/main.events"','reader completes while main.events.lock'),
 ('lease-open','leases','bin/project',"live, live_mtime = integer_file(Path(eventroot)/'attempts'/'.live')",
  "for lease in (Path(eventroot)/'attempts').glob('acme-core.*'):\n    try: lease.read_bytes()\n    except PermissionError: pass\nlive, live_mtime = integer_file(Path(eventroot)/'attempts'/'.live')",'lease FIFO is never opened'),
 ('fixed-temp','temps','bin/project','temp=$(mktemp "$projection_root/.$uid.json.XXXXXX")','temp="$projection_root/.$uid.json.fixed"','published candidate has random'),
 ('roster-validation','roster','bin/project','    aib_validate_agent_uid "$agent"','    : # validation removed','malformed registry agent fails closed'),
 ('dateless-nonlast','history','bin/project','            if is_last:','            if True:','non-last dateless production parser'),
 ('heartbeat-attestation','provenance','bin/project','attested=False','attested=True','heartbeat entry is agent-asserted'),
 ('capacity-attention','capacity','bin/project',"if status != 'ok':","if live is not None and live >= int(limit):\n    attention('stream_unhealthy',None,'capacity full',iso(now))\nif status != 'ok':",'capacity at/above limit derives no attention'),
 ('admission-release','admission','bin/aib-broker-handler','_live=0\n','exec {_admission_fd}>&-\n_live=0\n','live sample publication occurs under admission lock'),
]
with tempfile.TemporaryDirectory(prefix='aib-visibility-mutants.') as tmp:
    tree=pathlib.Path(tmp)
    for folder in ('bin','lib','tests'):
        shutil.copytree(root/folder,tree/folder,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    baseline=subprocess.run(['bash',str(tree/'tests/visibility_delta_spec.sh')],capture_output=True,text=True,timeout=90)
    check('clean delta acceptance is green',baseline.returncode==0 and '34 passed, 0 failed' in baseline.stdout)
    if baseline.returncode:print(baseline.stdout,baseline.stderr)
    for name,case,file,old,new,label in mutants:
        path=tree/file;original=path.read_text();count=original.count(old)
        check(name+': exact mutation target exists',count>0 if name=='heartbeat-attestation' else count==1)
        if not count:continue
        path.write_text(original.replace(old,new))
        try:
            result=subprocess.run(['bash',str(tree/'tests/visibility_delta_spec.sh'),case],capture_output=True,text=True,timeout=40)
            check(name+': mutant is refused',result.returncode!=0)
            check(name+': specific behavioral pin fails','FAIL - '+label in result.stdout)
            if result.returncode==0 or 'FAIL - '+label not in result.stdout:print(result.stdout,result.stderr)
        finally:path.write_text(original)
print(f'visibility_mutation_spec: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
