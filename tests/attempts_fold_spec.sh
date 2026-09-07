#!/usr/bin/env bash
# Fast shared fold: checksum differential, scan parity and semantic rejection.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import importlib.util,json,os,pathlib,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]); passed=failed=0
spec=importlib.util.spec_from_file_location('fold',root/'lib/attempts_fold.py')
try:
    fold=importlib.util.module_from_spec(spec); spec.loader.exec_module(fold)
except (FileNotFoundError, ImportError) as e:
    print('attempts_fold_spec: 0 passed, 1 failed'); sys.exit(1)
def check(label, value):
    global passed,failed
    if value: passed+=1
    else: failed+=1; print('FAIL - '+label)
def crc(data): return int(subprocess.check_output(['cksum'],input=data).split()[0])
for data in (b'', b'a', b'hello\n', bytes(range(256)), os.urandom(65536)):
    check('POSIX CRC agrees with coreutils',fold.cksum(data)==crc(data))
def record(seq=1,**changes):
    r=dict(event_id=f'acme-main-{seq}',attempt_id='acme-main-1',event_type='attempt.decided',agent_uid='acme-core',occurred_at='2026-09-07T00:00:00Z',payload=dict(decision='allow',pid=os.getpid()))
    r.update(changes); return r
def frame(r,seq):
    data=json.dumps(r,separators=(',',':')).encode();return f'{seq} {crc(data)} {len(data)} '.encode()+data+b'\n'
with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp)/'main.events'
    check('absent is reportable',fold.fold(path)['present'] is False)
    first=frame(record(),1)
    cases=[first,first+b'torn',first+frame(record(3,attempt_id='acme-main-3'),3),first+b'broken\n',first+first,first.replace(b'acme',b'acmf',1),frame(record(2),1)]
    for data in cases:
        path.write_bytes(data); got=fold.fold(path)
        cmd='. "$1/lib/aibobnet.sh"; aib_event_scan "$2" >/dev/null; printf "%s %s %s %s" "$AIB_EVENT_SCAN_STATUS" "$AIB_EVENT_SCAN_HIGHEST_SEQ" "$AIB_EVENT_SCAN_NEXT_SEQ" "$AIB_EVENT_SCAN_TORN_TAIL"'
        old=subprocess.check_output(['bash','-c',cmd,'_',str(root),str(path)],text=True)
        new=f"{got['status']} {got['highest']} {got['next']} {int(got['torn'])}"
        check('shared fold matches existing scanner metadata',old==new)
    bad=[record(payload={'decision':'bogus','pid':1}),record(payload={'decision':'allow','pid':0}),record(payload={'decision':'allow','pid':'bad'}),record(attempt_id=''),record(event_type='attempt.ended',payload={'exit':{'class':'ok'}})]
    for r in bad:
        path.write_bytes(frame(r,1)); got=fold.fold(path)
        check('invalid attempt cannot produce a partial fold',got['status']=='corrupt' and not got['attempts'])
    for exit in ({'class':'bad'},{'class':'timeout'},{'class':'ok','code':'bad'}):
        path.write_bytes(first+frame(record(2,event_type='attempt.ended',payload={'exit':exit}),2))
        check('invalid terminal rejected',fold.fold(path)['status']=='corrupt')
    ended=frame(record(2,event_type='attempt.ended',payload={'exit':{'class':'ok'}}),2)
    path.write_bytes(first+ended+frame(record(3,event_type='attempt.ended',payload={'exit':{'class':'ok'}}),3))
    check('duplicate terminal rejected',fold.fold(path)['status']=='corrupt')
    path.write_bytes(frame(record(payload={'decision':'deny','pid':1}),1)+ended)
    check('denied terminal rejected',fold.fold(path)['status']=='corrupt')
    path.write_bytes(first+frame(record(2),2))
    check('duplicate decided rejected',fold.fold(path)['status']=='corrupt')
print(f'attempts_fold_spec: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
