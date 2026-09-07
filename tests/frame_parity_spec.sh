#!/usr/bin/env bash
# Permanent frame corpus: Bash reference vs Python reader, plus the main CLI.
# attempts_main.sh is the unmodified CLI at 240df04, run with the reference lib.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import importlib.util,json,os,pathlib,subprocess,sys,tempfile
sys.dont_write_bytecode=True
root=pathlib.Path(sys.argv[1]);passed=failed=0
spec=importlib.util.spec_from_file_location('reader',root/'lib/attempts_fold.py')
reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
def check(label,value):
    global passed,failed
    if value:passed+=1;print('ok - '+label)
    else:failed+=1;print('FAIL - '+label)
def crc(data):return subprocess.check_output(['cksum'],input=data).split()[0]
def record(seq=1,**updates):
    obj=dict(event_id=f'acme-main-{seq}',attempt_id=f'acme-main-{seq}',event_type='attempt.decided',agent_uid='acme-core',occurred_at='2026-09-07T00:00:00Z',payload={'decision':'allow','pid':os.getpid()})
    obj.update(updates);return json.dumps(obj,separators=(',',':')).encode()
def frame(seq,data,length=None,checksum=None):
    return str(seq).encode()+b' '+(crc(data) if checksum is None else checksum)+b' '+str(len(data) if length is None else length).encode()+b' '+data+b'\n'
first=frame(1,record());second=frame(2,record(2))
invalid=record().replace(b'"payload":{',b'"note":"\xff","payload":{')
invalid_token=record().replace(b'"payload":{',b'"note":\xff,"payload":{')
nul=record().replace(b'"payload":{',b'"note":"\0","payload":{')
cases={
 'baseline':first+second,
 'CRC-corrupt':first+frame(2,record(2),checksum=b'0'),
 'sequence gap':first+frame(3,record(3)),
 'torn tail':first+second[:-1],
 'embedded NUL':first+frame(2,nul.replace(b'main-1',b'main-2')),
 'invalid UTF-8 payload':frame(1,invalid)+second,
 'length mismatch':first+frame(2,record(2),length=len(record(2))+1),
 'oversize record':frame(1,record(note='x'*70000))+second,
 'non-JSON body':first+frame(2,b'[]'),
 'invalid UTF-8 token':frame(1,invalid_token)+second,
 'event identity mismatch':first+frame(2,record(3)),
 'duplicate sequence':first+first,
 'NUL-only unterminated tail':first+b'\0',
 'NUL elided before checksum':frame(1,nul,length=len(nul)-1,checksum=crc(nul.replace(b'\0',b'')))+second,
 'zero-padded sequence':frame('01',record('01'))+second,
 'zero-padded highest':frame('01',record('01')),
}
# Coreutils is also the checksum oracle at suffix-length boundaries.
if hasattr(reader,'cksum'):
    for size in (0,1,255,256,257,65535,65536,65537):
        data=b'x'*size;check('CRC parity length '+str(size),str(reader.cksum(data)).encode()==crc(data))
else:check('fast reader checksum exists',False)
with tempfile.TemporaryDirectory(prefix='aib-frame-parity.') as tmp:
    work=pathlib.Path(tmp);home=work/'acme';standup=home/'standup';(standup/'events').mkdir(parents=True)
    events=standup/'events/main.events';refbin=work/'reference/bin';refbin.mkdir(parents=True)
    (refbin.parent/'lib').symlink_to(root/'lib',target_is_directory=True)
    legacy=refbin/'attempts';legacy.write_bytes((root/'tests/fixtures/attempts_main.sh').read_bytes());legacy.chmod(0o755)
    registry={'schema_version':4,'providers':{'codex':{'adapter':'/bin/true','cap_sandbox':'workspace-write','cap_tier':'t3','cap_effort':'high','cap_timeout':'900'}},'projects':{'acme':{'home':str(home),'standup_dir':str(standup),'mux_session':'acme','provider':'codex','model':'m','effort':'low'}},'agents':{'acme-core':{'project':'acme','profile':'engine-dev','clearance':'t2'}}}
    reg=work/'registry.json';reg.write_text(json.dumps(registry))
    env=dict(os.environ,AIBOBNET_REGISTRY=str(reg),LC_ALL='C')
    command='. "$1/lib/aibobnet.sh"; aib_event_scan "$2" > "$3"; printf "%s\\n" "$AIB_EVENT_SCAN_STATUS" "$AIB_EVENT_SCAN_HIGHEST_SEQ" "$AIB_EVENT_SCAN_NEXT_SEQ" "$AIB_EVENT_SCAN_TORN_TAIL" "$AIB_EVENT_SCAN_TRUNCATE_AT" "$AIB_EVENT_SCAN_CORRUPT_REASON"'
    has_scan=hasattr(reader,'scan');check('Python frame pass is independently callable',has_scan)
    for name,data in cases.items():
        events.write_bytes(data);emitted=work/'records'
        raw=subprocess.check_output(['bash','-c',command,'_',str(root),str(events),str(emitted)],env=env)
        status,highest,nxt,torn,truncate,reason=raw.decode('utf-8',errors='surrogateescape').splitlines()
        if has_scan:
            got,records=reader.scan(events)
            check(name+': frame status',got['status']==status)
            check(name+': NEXT_SEQ',got['next']==int(nxt))
            check(name+': highest/torn/truncate/reason',(got['highest'],got['torn'],got['truncate_at'],got['reason'])==(int(highest),bool(int(torn)),int(truncate),reason))
            intact=b''.join(seq+b'\t'+body+b'\n' for seq,body in records)
            check(name+': exact intact-record set',intact==emitted.read_bytes())
            if name.startswith('invalid UTF-8'):
                folded=reader.fold(events)
                check(name+': record anomaly and later visibility',folded['status']=='ok' and folded['undecodable_records']==[1] and [a['id'] for a in folded['attempts']]==['acme-main-2'])
        for locale in ('C','C.UTF-8'):
            env['LC_ALL']=locale
            old=subprocess.run([str(legacy),'acme-core'],env=env,capture_output=True)
            new=subprocess.run([str(root/'bin/attempts'),'acme-core'],env=env,capture_output=True)
            check(name+': main CLI bytes/exit in '+locale,(new.returncode,new.stdout,new.stderr)==(old.returncode,old.stdout,old.stderr))
        env['LC_ALL']='C'
print(f'frame_parity_spec: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
