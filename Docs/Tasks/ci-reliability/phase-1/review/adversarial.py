import json,os,signal,subprocess,sys,time
from pathlib import Path
from contextlib import suppress
ROOT=Path.cwd(); BASE=ROOT/'.build/reviewer-phase1'
sys.path.insert(0,str(ROOT/'Tools/ci')); import linux_ci as ci

def running(pid):
    try: os.kill(pid,0)
    except ProcessLookupError: return False
    result=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True,timeout=1)
    return result.returncode==0 and not result.stdout.lstrip().startswith('Z')

def cleanup(path):
    if path.exists():
        with suppress(ProcessLookupError): os.kill(int(path.read_text()),signal.SIGKILL)

def waitfile(path,seconds=2):
    deadline=time.monotonic()+seconds
    while not path.exists() and time.monotonic()<deadline: time.sleep(.01)
    assert path.exists(),path

def run_worker(name,code,stdout=subprocess.DEVNULL,action=None):
    script=BASE/('worker-'+name+'.py'); script.write_text("import json,os,signal,subprocess,sys,time\nfrom pathlib import Path\nsys.path.insert(0,"+repr(str(ROOT/'Tools/ci'))+")\nimport linux_ci as ci\nroot=Path("+repr(str(ROOT))+")\nbase=Path("+repr(str(BASE))+ ")\n"+code)
    (BASE/(name+'.receipt.json')).unlink(missing_ok=True)
    started=time.monotonic(); process=subprocess.Popen([sys.executable,str(script)],stdout=stdout,stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        if action: action(process)
        status=process.wait(timeout=10)
        return {'returnCode':status,'seconds':round(time.monotonic()-started,3)}
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=1)
        return {'timeout':True,'seconds':round(time.monotonic()-started,3)}
    finally:
        if process.stdout: process.stdout.close()

results={}
# Successful parent closes all output while a TERM-resistant child keeps running.
pidfile=BASE/'closed-output.pid'
pidfile.unlink(missing_ok=True)
child="import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path("+repr(str(pidfile))+").write_text(str(os.getpid()));time.sleep(60)"
parent="import subprocess,sys,time;from pathlib import Path;subprocess.Popen([sys.executable,'-c',"+repr(child)+"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);p=Path("+repr(str(pidfile))+");exec('while not p.exists(): time.sleep(.01)')"
try:
    result=run_worker('closed-output',"ci.execute(ci.Command('closed-output',(sys.executable,'-c',"+repr(parent)+"),1.5),root,base/'closed-output.log')\n")
    result.update(childAlive=running(int(pidfile.read_text())),receipt=json.loads((BASE/'closed-output.receipt.json').read_text()))
    results['successClosedOutputDescendant']=result
finally: cleanup(pidfile)
# Actual supervisor SIGTERM, not a mocked exception.
pidfile=BASE/'signal-child.pid'
pidfile.unlink(missing_ok=True)
child="import os,time;from pathlib import Path;Path("+repr(str(pidfile))+").write_text(str(os.getpid()));time.sleep(60)"
try:
    result=run_worker('signal',"ci.execute(ci.Command('signal',(sys.executable,'-c',"+repr(child)+"),60),root,base/'signal.log')\n",action=lambda p:(waitfile(pidfile),p.send_signal(signal.SIGTERM)))
    result.update(childAlive=running(int(pidfile.read_text())),receipt=json.loads((BASE/'signal.receipt.json').read_text()));results['realSIGTERM']=result
finally: cleanup(pidfile)
# Real stdout pipe becomes saturated; nothing reads it until worker terminates.
code="ci.execute(ci.Command('blocked-console',(sys.executable,'-c',\"import os;os.write(1,b'x'*1000000)\"),1),root,base/'blocked-console.log')\n"
results['blockedConsolePipe']=run_worker('blocked-console',code,stdout=subprocess.PIPE)
results['blockedConsolePipe']['receipt']=json.loads((BASE/'blocked-console.receipt.json').read_text())
# Big output without a newline: bounded prefix for normal logs; exact discovery must fail.
for exact in (False,True):
    name='flood-discovery' if exact else 'flood-normal'
    code="ci._console_write=lambda text:None\nci.execute(ci.Command("+repr(name)+",(sys.executable,'-c',\"import os;os.write(1,b'x'*9000000)\"),2),root,base/"+repr(name+'.log')+(",stdout_log=base/'flood-discovery.stdout'" if exact else '')+")\n"
    results[name]=run_worker(name,code); results[name]['receipt']=json.loads((BASE/(name+'.receipt.json')).read_text())
# Successful debugger parent with a descendant retaining stdout is still bounded.
pidfile=BASE/'probe-child.pid'
pidfile.unlink(missing_ok=True)
child="import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path("+repr(str(pidfile))+").write_text(str(os.getpid()));time.sleep(60)"
parent="import subprocess,sys,time;from pathlib import Path;subprocess.Popen([sys.executable,'-c',"+repr(child)+"]);p=Path("+repr(str(pidfile))+");exec('while not p.exists(): time.sleep(.01)')"
try:
    started=time.monotonic(); result=ci._probe((sys.executable,'-c',parent),time.monotonic()+.4)
    result.update(wallSeconds=round(time.monotonic()-started,3),childAlive=running(int(pidfile.read_text()))); results['probePipeHolder']=result
finally: cleanup(pidfile)
# Escaped session is deliberately outside process-group guarantee and cleaned by test owner.
pidfile=BASE/'escaped-child.pid'
pidfile.unlink(missing_ok=True)
child="import os,time;from pathlib import Path;Path("+repr(str(pidfile))+").write_text(str(os.getpid()));time.sleep(60)"
parent="import subprocess,sys,time;from pathlib import Path;subprocess.Popen([sys.executable,'-c',"+repr(child)+"],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);p=Path("+repr(str(pidfile))+");exec('while not p.exists(): time.sleep(.01)')"
try:
    result=run_worker('escaped',"ci.execute(ci.Command('escaped',(sys.executable,'-c',"+repr(parent)+"),1.5),root,base/'escaped.log')\n")
    result.update(childAlive=running(int(pidfile.read_text())),receipt=json.loads((BASE/'escaped.receipt.json').read_text()));results['escapedSessionBoundary']=result
finally: cleanup(pidfile)
(BASE/'results.json').write_text(json.dumps(results,indent=2)+'\n')
for name,result in results.items():
    receipt=result.get('receipt',{})
    print(name,json.dumps({k:v for k,v in result.items() if k!='receipt'}),receipt.get('status'),receipt.get('cleanup',{}).get('groupState'),receipt.get('outputs'))
