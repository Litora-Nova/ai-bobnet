#!/usr/bin/env bash
# Shared fold: canonical scanner parity, decode anomalies and semantic rejection.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import importlib.util,json,os,pathlib,subprocess,sys,tempfile
sys.dont_write_bytecode=True
root=pathlib.Path(sys.argv[1]); passed=failed=0
def shared(path):
    cmd='. "$1/lib/aibobnet.sh"; REPO_ROOT="$1"; aib_attempts_fold "$2"'
    return json.loads(subprocess.check_output(['bash','-c',cmd,'_',str(root),str(path)]))
def check(label, value):
    global passed,failed
    if value: passed+=1
    else: failed+=1; print('FAIL - '+label)
def crc(data): return int(subprocess.check_output(['cksum'],input=data).split()[0])
def record(seq=1,**changes):
    r=dict(event_id=f'acme-main-{seq}',attempt_id='acme-main-1',event_type='attempt.decided',agent_uid='acme-core',occurred_at='2026-09-07T00:00:00Z',payload=dict(decision='allow',pid=os.getpid()))
    r.update(changes); return r
def frame(r,seq):
    data=json.dumps(r,separators=(',',':')).encode();return f'{seq} {crc(data)} {len(data)} '.encode()+data+b'\n'
with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp)/'main.events'
    check('absent is reportable',shared(path)['present'] is False)
    first=frame(record(),1)
    cases=[first,first+b'torn',first+frame(record(3,attempt_id='acme-main-3'),3),first+b'broken\n',first+first,first.replace(b'acme',b'acmf',1),frame(record(2),1)]
    for data in cases:
        path.write_bytes(data); got=shared(path)
        cmd='. "$1/lib/aibobnet.sh"; aib_event_scan "$2" >/dev/null; printf "%s %s %s %s" "$AIB_EVENT_SCAN_STATUS" "$AIB_EVENT_SCAN_HIGHEST_SEQ" "$AIB_EVENT_SCAN_NEXT_SEQ" "$AIB_EVENT_SCAN_TORN_TAIL"'
        old=subprocess.check_output(['bash','-c',cmd,'_',str(root),str(path)],text=True)
        new=f"{got['status']} {got['highest']} {got['next']} {int(got['torn'])}"
        check('shared fold matches existing scanner metadata',old==new)
    bad=[record(payload={'decision':'bogus','pid':1}),record(payload={'decision':'allow','pid':0}),record(payload={'decision':'allow','pid':'bad'}),record(attempt_id=''),record(attempt_id='bad\n1'),record(event_type='attempt.ended',payload={'exit':{'class':'ok'}})]
    for r in bad:
        path.write_bytes(frame(r,1)); got=shared(path)
        check('invalid attempt cannot produce a partial fold',got['status']=='corrupt' and not got['attempts'])
    for exit in ({'class':'bad'},{'class':'timeout'},{'class':'ok','code':'bad'}):
        path.write_bytes(first+frame(record(2,event_type='attempt.ended',payload={'exit':exit}),2))
        check('invalid terminal rejected',shared(path)['status']=='corrupt')
    ended=frame(record(2,event_type='attempt.ended',payload={'exit':{'class':'ok'}}),2)
    path.write_bytes(first+ended+frame(record(3,event_type='attempt.ended',payload={'exit':{'class':'ok'}}),3))
    check('duplicate terminal rejected',shared(path)['status']=='corrupt')
    path.write_bytes(frame(record(payload={'decision':'deny','pid':1}),1)+ended)
    check('denied terminal rejected',shared(path)['status']=='corrupt')
    path.write_bytes(first+frame(record(2),2))
    check('duplicate decided rejected',shared(path)['status']=='corrupt')
    data=json.dumps(record(),separators=(',',':')).encode().replace(b'"decision":"allow"',b'"decision":"deny","decision":"allow"')
    path.write_bytes(f'1 {crc(data)} {len(data)} '.encode()+data+b'\n')
    check('duplicate JSON keys cannot select a conflicting truth',shared(path)['status']=='corrupt')
with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp)/'main.events'
    for label,byte in [('invalid UTF-8',b'\xff'),('NUL',b'\0')]:
        data=json.dumps(record(),separators=(',',':')).encode().replace(b'"payload":{',b'"note":"'+byte+b'","payload":{')
        path.write_bytes(f'1 {crc(data)} {len(data)} '.encode()+data+b'\n'+frame(record(2,attempt_id='acme-main-2'),2))
        got=shared(path)
        cmd='. "$1/lib/aibobnet.sh"; aib_event_scan "$2" >/dev/null; printf "%s %s %s %s" "$AIB_EVENT_SCAN_STATUS" "$AIB_EVENT_SCAN_HIGHEST_SEQ" "$AIB_EVENT_SCAN_NEXT_SEQ" "$AIB_EVENT_SCAN_TORN_TAIL"'
        old=subprocess.check_output(['bash','-c',cmd,'_',str(root),str(path)],text=True)
        new=f"{got['status']} {got['highest']} {got['next']} {int(got['torn'])}"
        check(label+' metadata agrees with scanner',old==new)
        if label=='invalid UTF-8':
            check('undecodable sequence is recorded',got.get('undecodable_records')==[1])
            check('later valid attempt stays visible',any(a['id']=='acme-main-2' for a in got['attempts']))
            check('legacy fold retains frame-intact bad-byte attempt',any(a['id']=='acme-main-1' for a in got.get('legacy_attempts',[])))
    path.write_bytes(b'broken\n')
    got=shared(path)
    check('corruption reason is canonical',got['reason']=='unparsable framed record near offset 0')
    # Poison the scanner response: the wrapper must consume the canonical scan,
    # rather than opening the raw source independently in a second authority.
    cmd='. "$1/lib/aibobnet.sh"; REPO_ROOT="$1"; aib_event_scan() { AIB_EVENT_SCAN_STATUS=corrupt; AIB_EVENT_SCAN_HIGHEST_SEQ=0; AIB_EVENT_SCAN_NEXT_SEQ=1; AIB_EVENT_SCAN_TORN_TAIL=0; AIB_EVENT_SCAN_CORRUPT_REASON="scanner canary"; }; aib_attempts_fold "$2"'
    got=json.loads(subprocess.check_output(['bash','-c',cmd,'_',str(root),str(path)]))
    check('Bash scanner is the only frame authority',got['reason']=='scanner canary')
for fake,expected in [("printf 'ok\\n'",2),("return 9",9)]:
    cmd='. "$1/lib/aibobnet.sh"; REPO_ROOT="$1"; python3() { '+fake+'; }; aib_attempts_fold /nonexistent'
    result=subprocess.run(['bash','-c',cmd,'_',str(root)],capture_output=True)
    check('shell fold rejects failed or incomplete helper output',result.returncode==expected and not result.stdout)
print(f'attempts_fold_spec: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
