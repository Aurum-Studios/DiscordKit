from pathlib import Path
import ast, hashlib, json, re, subprocess
from urllib.parse import unquote
root=Path.cwd()
phase=root/'Docs/Tasks/ci-reliability/phase-8'
changed=subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()
new=subprocess.check_output(['git','ls-files','--others','--exclude-standard','Tools/ci'],text=True).splitlines()
source=sorted(set(p for p in changed+new if p.startswith(('Tools/ci/','.github/'))))
parsed=[]
for name in source:
    if name.endswith('.py'):
        ast.parse((root/name).read_text(),filename=name)
        parsed.append(name)
embedded=0
for path in [*root.glob('.github/workflows/*.yml'), *root.glob('.github/actions/*/action.yml')]:
    lines=path.read_text().splitlines()
    for i,line in enumerate(lines):
        if not re.match(r'\s+run: \|[-+]?$',line): continue
        indent=len(line)-len(line.lstrip())
        before='\n'.join(lines[max(0,i-22):i])
        # Only explicit Python step bodies, with no intervening step boundary.
        step_start=max((k for k in range(i) if re.match(r'\s+- (name:|uses:)',lines[k])),default=0)
        if not any(re.match(r'\s+shell: python$',l) for l in lines[step_start:i]): continue
        body=[]
        for child in lines[i+1:]:
            if child.strip() and len(child)-len(child.lstrip())<=indent: break
            body.append(child[indent+2:])
        ast.parse('\n'.join(body),filename=str(path))
        embedded+=1
json_count=0
for path in phase.rglob('*.json'):
    json.loads(path.read_text()); json_count+=1
links=0
for path in [root/'Docs/CI.md', *root.glob('Docs/Tasks/ci-reliability/*.md'), *phase.rglob('*.md')]:
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)',path.read_text()):
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:',target) or target.startswith('#'): continue
        dest=unquote(target.split('#',1)[0].split('?',1)[0])
        assert (path.parent/dest).exists(), (path,target)
        links+=1
preflight=json.loads((phase/'source-preflight.json').read_text())
for name,expected in preflight['originalPlanningSHA256'].items():
    assert hashlib.sha256((root.parent/'DiscordKit'/name).read_bytes()).hexdigest()==expected, name
import sys
sys.path.insert(0,str(root/'Tools/ci'))
import native_provisioning, scheduling_policy
assert native_provisioning.load_policy()['allowanceSeconds']==scheduling_policy.load_policy()['reservesSeconds']['setup']==600
for name, expected in json.loads((phase/'checks/real-macos-payload/check.json').read_text())['sourceSHA256'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected,name
record={'status':'passed','pythonFiles':parsed,'embeddedPythonBlocks':embedded,'jsonFiles':json_count,
        'localMarkdownLinks':links,'originalPlanningHashesUnchanged':True,'realPayloadCheckSourceHashesMatch':True,
        'provisioningMatchesSchedulingSetupSeconds':600}
(phase/'checks/static/results.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,sort_keys=True))
