#!/usr/bin/env bash
# Visibility gate regressions. Optional case argument supports focused mutation runs.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" "${1:-all}" <<'PY'
import ast,contextlib,datetime as dt,fcntl,io,json,os,pathlib,re,signal,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]); selected=sys.argv[2]; passed=failed=0

def check(label,condition):
    global passed,failed
    if condition: passed+=1; print('ok - '+label)
    else: failed+=1; print('FAIL - '+label)

def run(args,env,timeout=5,input=None):
    p=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try: out,err=p.communicate(input,timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate();return 124,out,err
    return p.returncode,out,err

@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='aib-visibility-delta.') as tmp:
        w=pathlib.Path(tmp); home=w/'acme';standup=home/'standup';standup.mkdir(parents=True)
        events=w/'events';(events/'acme').mkdir(parents=True);(events/'attempts').mkdir()
        (standup/'events').symlink_to(events/'acme',target_is_directory=True)
        (events/'acme/main.events').touch()
        registry={'schema_version':4,'providers':{'codex':{'adapter':'/bin/true','cap_sandbox':'workspace-write','cap_tier':'t3','cap_effort':'high','cap_timeout':'900'}},'projects':{'acme':{'home':str(home),'standup_dir':str(standup),'mux_session':'acme','provider':'codex','model':'m','effort':'low'}},'agents':{'acme-core':{'project':'acme','profile':'engine-dev','clearance':'t2'}}}
        reg=w/'registry.json';reg.write_text(json.dumps(registry))
        env=dict(os.environ,AIBOBNET_REGISTRY=str(reg),AIB_EVENT_ROOT=str(events),AIB_PROJECTION_ROOT=str(w/'output'),TZ='UTC')
        yield w,standup,events,registry,env

def project(env):
    rc,out,err=run([str(root/'bin/project'),'acme','--stdout'],env)
    try: data=json.loads(out)
    except ValueError: data={}
    return rc,data,err

def functions():
    source=(root/'bin/project').read_text().split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
    tree=ast.parse(source)
    # Execute production imports/functions only; no projector top-level I/O.
    tree.body=[n for n in tree.body if isinstance(n,(ast.Import,ast.ImportFrom,ast.FunctionDef))]
    ns={};exec(compile(tree,'bin/project','exec'),ns)
    ns['zone']=ns['ZoneInfo']('UTC')
    return ns

def locks():
    with fixture() as (w,s,e,r,env):
        for path in (e/'acme/main.events.lock',e/'attempts/attempts.lock'):
            with path.open('w') as f:
                fcntl.flock(f,fcntl.LOCK_EX)
                rc,_,_=project(env)
                check('reader completes while '+path.name+' is exclusively held',rc==0)

def leases():
    with fixture() as (w,s,e,r,env):
        canary=e/'attempts/acme-core.0';canary.touch();canary.chmod(0)
        rc,_,_=project(env);check('unreadable lease does not affect reader',rc==0)
        os.mkfifo(e/'attempts/acme-core.1')
        rc,_,_=project(env);check('lease FIFO is never opened by reader',rc==0)

def temps():
    with fixture() as (w,s,e,r,env):
        output=w/'output';output.mkdir();target=w/'untouched';target.write_text('canary')
        for name in ('.acme.json.tmp','.acme.json.fixed','acme.json.tmp'):(output/name).symlink_to(target)
        bindir=w/'bin';bindir.mkdir();log=w/'rename-source'
        mv=bindir/'mv';mv.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "${@: -2:1}" >> "$RENAME_LOG"\nexec /bin/mv "$@"\n');mv.chmod(0o755)
        env.update(PATH=str(bindir)+':'+env['PATH'],RENAME_LOG=str(log))
        rc,_,_=project(env);check('preplanted fixed-name symlinks cannot redirect publication',rc==0 and target.read_text()=='canary')
        names=log.read_text().splitlines() if log.exists() else []
        check('published candidate has random six-character suffix',len(names)==1 and re.fullmatch(r'\.acme\.json\.[A-Za-z0-9]{6}',pathlib.Path(names[0]).name) is not None)

def roster():
    with fixture() as (w,s,e,r,env):
        r['agents']['ACME_BAD']=r['agents']['acme-core'];pathlib.Path(env['AIBOBNET_REGISTRY']).write_text(json.dumps(r))
        rc,data,_=project(env);check('malformed registry agent fails closed and never becomes a key',rc!=0 and 'ACME_BAD' not in data.get('agents',{}))

def history():
    with fixture() as (w,s,e,r,env):
        log=s/'acme-core.log';log.write_text('2026-09-07 08:00 | busy | first\n09:00 | blocked | old\n2026-09-07 10:00 | done | last\n')
        rc,data,_=project(env);check('dated last line wins over non-last dateless history',rc==0 and data['agents']['acme-core']['state']=='done')
        ns=functions()
        try:
            beat=ns['parse_beat_line']('09:00 | blocked | old',42,False,'acme-core')
            check('non-last dateless production parser has no timestamp',beat['epoch'] is None and beat['stale'] is True)
        except KeyError:check('non-last dateless production parser has no timestamp',False)

def provenance():
    with fixture() as (w,s,e,r,env):
        for text in ('','broken','2026-09-07 10:00 | blocked | needs:human review'):
            (s/'acme-core.log').write_text(text)
            rc,data,_=project(env)
            check('heartbeat entry is agent-asserted for '+repr(text),rc==0 and data['agents']['acme-core']['attested'] is False)
            if text.startswith('2026'):
                check('needs attention is agent-asserted',all(x['attested'] is False for x in data['attention']))
        (e/'acme/main.events').write_text('broken\n')
        rc,data,_=project(env);check('stream health attention is broker-attested',rc==0 and any(x['kind']=='stream_unhealthy' and x['attested'] is True for x in data['attention']))

def capacity():
    with fixture() as (w,s,e,r,env):
        env['AIB_BROKER_CAPACITY']='12'
        for live in (12,13):
            (e/'attempts/.live').write_text(str(live)+'\n')
            rc,data,_=project(env);check('capacity at/above limit derives no attention: '+str(live),rc==0 and data['capacity']['live']==live and data['attention']==[])

def boundary():
    ns=functions()
    for age,expected in ((899,False),(900,False),(901,True)):
        try:got=ns['presumed_dead'](10000,10000-age,None,15)
        except KeyError:got=None
        check('presumed-dead strict threshold age '+str(age),got is expected)

def projects():
    with fixture() as (w,s,e,r,env):
        r['agents']={};pathlib.Path(env['AIBOBNET_REGISTRY']).write_text(json.dumps(r))
        rc,data,_=project(env);check('project with zero agents publishes empty object',rc==0 and data['agents']=={})
        home=w/'beta';home.mkdir();r['projects']['beta']=dict(r['projects']['acme'],home=str(home),mux_session='beta')
        r['agents']={a:{'project':p,'profile':'engine-dev','clearance':'t2'} for a,p in [('acme-core','acme'),('beta-core','beta')]}
        for a,state in [('acme-core','busy'),('beta-core','idle')]: (s/(a+'.log')).write_text('2026-09-07 10:00 | '+state+' | shared\n')
        pathlib.Path(env['AIBOBNET_REGISTRY']).write_text(json.dumps(r));(e/'beta').mkdir();(e/'beta/main.events').touch()
        rc,out,_=run([str(root/'bin/project'),'--all'],env)
        check('shared standup projects both publish',rc==0)
        for p,agent in [('acme','acme-core'),('beta','beta-core')]:
            d=json.loads((w/'output'/(p+'.json')).read_text());check('shared standup isolates '+p,set(d['agents'])=={agent} and d['anomalies']['unregistered_logs']==1)

def admission():
    with fixture() as (w,s,e,r,env):
        # Observe both externally visible critical-section operations. The probe
        # child closes inherited descriptors before independently testing flock.
        bindir=w/'bin';bindir.mkdir();log=w/'lock-observations'
        probe=w/'probe.py';probe.write_text('import fcntl,os,sys\nf=open(sys.argv[1],"a")\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); held=False\nexcept BlockingIOError: held=True\nwith open(sys.argv[2],"a") as out: out.write(sys.argv[3]+":"+str(held)+"\\n")\n')
        wrapper='#!/usr/bin/env python3\nimport os,subprocess,sys\nargs=sys.argv[1:]\nreal="/usr/bin/"+os.path.basename(sys.argv[0])\nobserve=False\nif real.endswith("/mv"): observe=args[-1].endswith("/.live")\nelse:\n try: observe="acme-core." in os.readlink("/proc/self/fd/"+args[-1])\n except OSError: pass\nif observe: subprocess.run([sys.executable,os.environ["LOCK_PROBE"],os.environ["ADMISSION_LOCK"],os.environ["LOCK_LOG"],os.path.basename(real)],close_fds=True,check=True)\nos.execv(real,[real]+args)\n'
        for cmd in ('mv','flock'):
            p=bindir/cmd;p.write_text(wrapper);p.chmod(0o755)
        env.update(PATH=str(bindir)+':'+env['PATH'],LOCK_PROBE=str(probe),ADMISSION_LOCK=str(e/'attempts/attempts.lock'),LOCK_LOG=str(log),AIBOBNET_REGISTRY='/nonexistent')
        rc,out,err=run([str(root/'bin/aib-broker-handler')],env,input=b'op=launch\nagent_uid=acme-core\nprompt_bytes=2\n\nhi')
        seen=log.read_text().splitlines() if log.exists() else []
        check('live sample publication occurs under admission lock','mv:True' in seen and 'mv:False' not in seen)
        check('lease allocation occurs under admission lock','flock:True' in seen and 'flock:False' not in seen)
        check('lock-observed handler retains admission response',b'reason=registry_unavailable' in out)

def records():
    with fixture() as (w,s,e,r,env):
        def frame(seq,raw):
            crc=subprocess.check_output(['cksum'],input=raw).split()[0]
            return str(seq).encode()+b' '+crc+b' '+str(len(raw)).encode()+b' '+raw+b'\n'
        def record(seq,pid=99999999):
            return json.dumps(dict(event_id='acme-main-'+str(seq),attempt_id='acme-main-'+str(seq),event_type='attempt.decided',agent_uid='acme-core',occurred_at='2026-09-07T00:00:00Z',payload={'decision':'allow','pid':pid}),separators=(',',':')).encode()
        bad=record(1).replace(b'"payload":{',b'"note":"\xff","payload":{')
        (e/'acme/main.events').write_bytes(frame(1,bad)+frame(2,record(2)))
        rc,data,_=project(env)
        check('undecodable payload does not blind healthy stream',rc==0 and data['stream']['status']=='ok' and data['stream']['last_seq']==2)
        check('undecodable sequence is listed and counted',data.get('stream',{}).get('undecodable_records')==[1] and data.get('anomalies',{}).get('undecodable_records')==1)
        check('valid attempt after undecodable record remains projected',data.get('agents',{}).get('acme-core',{}).get('attempt',{}).get('id')=='acme-main-2')
        rc,out,err=run([str(root/'bin/attempts'),'acme-core'],env)
        expected=b'stream_status:ok | integrity:ok | highest_seq:2 | next_seq:3 | uncommitted_tail:0\n'+b''.join(('attempt_id:acme-main-'+str(n)+' | state:presumed-dead | decision:allow | pid:99999999 | exit_code:null\n').encode() for n in (1,2))
        check('legacy attempts bad-byte fixture retains exact stdout/stderr and exit',rc==0 and out==expected and err==b'')
        for raw,reason in [(b'broken\n',b'event stream is corrupt (unparsable framed record near offset 0) \xe2\x80\x94 refusing partial attempt fold'),(frame(1,record(1,0)),b"attempt 'acme-main-1' has non-positive pid '0'")]:
            (e/'acme/main.events').write_bytes(raw)
            rc,out,err=run([str(root/'bin/attempts'),'acme-core'],env)
            check('legacy corruption diagnostic is byte-identical: '+repr(reason),rc==2 and out==b'' and err==b'ai-bobnet: '+reason+b'\n')

cases={f.__name__:f for f in (locks,leases,temps,roster,history,provenance,capacity,boundary,projects,admission,records)}
for name,fn in cases.items():
    if selected in ('all',name):
        try:fn()
        except Exception as error:check(name+' raised '+repr(error),False)
print(f'visibility_delta_spec: {passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
