"""GitHub Actions helper using the credential git already has (never printed).

Usage:
  python actions.py dispatch OWNER/REPO WORKFLOW_FILE REF key=value...
  python actions.py runs OWNER/REPO WORKFLOW_FILE
  python actions.py jobs OWNER/REPO RUN_ID
  python actions.py log OWNER/REPO JOB_ID [LINES]
  python actions.py artifact OWNER/REPO RUN_ID ARTIFACT_NAME DEST.zip
  python actions.py cancel OWNER/REPO RUN_ID
  python actions.py rerun-failed OWNER/REPO RUN_ID   (only what failed or was cancelled, reusing what built)
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request


def token():
    out = subprocess.run(
        ['git', 'credential', 'fill'],
        input='protocol=https\nhost=github.com\n\n',
        capture_output=True, text=True, timeout=30,
        env={**os.environ, 'GCM_INTERACTIVE': 'never', 'GIT_TERMINAL_PROMPT': '0'},
    ).stdout
    fields = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
    if not fields.get('password'):
        raise SystemExit('no GitHub credential available')
    return fields['password']


TOKEN = token()


def call(method, path, body=None, raw=False):
    req = urllib.request.Request(
        f'https://api.github.com{path}', method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            'Authorization': f'Bearer {TOKEN}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'actions-script',
            **({'Content-Type': 'application/json'} if body is not None else {}),
        })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
            if raw:
                return r.status, data.decode(errors='replace')
            return r.status, json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors='replace')[:500]


cmd, repo, *rest = sys.argv[1:]
if cmd == 'dispatch':
    workflow, ref, *pairs = rest
    inputs = dict(p.split('=', 1) for p in pairs)
    print(call('POST', f'/repos/{repo}/actions/workflows/{workflow}/dispatches',
               {'ref': ref, 'inputs': inputs}))
elif cmd == 'rerun-failed':
    print(call('POST', f'/repos/{repo}/actions/runs/{rest[0]}/rerun-failed-jobs'))
elif cmd == 'runs':
    status, data = call('GET', f'/repos/{repo}/actions/workflows/{rest[0]}/runs?per_page=5')
    if status != 200:
        raise SystemExit(f'{status} {data}')
    for run in data['workflow_runs']:
        print(run['id'], run['event'], run['status'], run['conclusion'], run['created_at'], run['html_url'])
elif cmd == 'jobs':
    status, data = call('GET', f'/repos/{repo}/actions/runs/{rest[0]}/jobs')
    for job in data['jobs']:
        steps = [f"{s['name']}={s['conclusion'] or s['status']}" for s in job['steps']]
        print(job['id'], job['name'], job['status'], job['conclusion'])
        for s in steps:
            print('   ', s)
elif cmd == 'log':
    # The API redirects to a signed storage URL, which rejects our token:
    # read the redirect, then fetch it without credentials.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    req = urllib.request.Request(
        f'https://api.github.com/repos/{repo}/actions/jobs/{rest[0]}/logs',
        headers={'Authorization': f'Bearer {TOKEN}', 'User-Agent': 'actions-script'})
    try:
        urllib.request.build_opener(NoRedirect).open(req, timeout=60)
        raise SystemExit('expected a redirect')
    except urllib.error.HTTPError as e:
        location = e.headers['Location']
    with urllib.request.urlopen(location, timeout=120) as r:
        text = r.read().decode('utf-8-sig', errors='replace')
    lines = text.splitlines()
    n = int(rest[1]) if len(rest) > 1 else 60
    print('\n'.join(lines[-n:]))
if cmd == 'artifact':
    run_id, name, dest = rest
    status, data = call('GET', f'/repos/{repo}/actions/runs/{run_id}/artifacts')
    art = next(a for a in data['artifacts'] if a['name'] == name)
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    req = urllib.request.Request(art['archive_download_url'],
        headers={'Authorization': f'Bearer {TOKEN}', 'User-Agent': 'actions-script'})
    try:
        urllib.request.build_opener(NoRedirect).open(req, timeout=60)
    except urllib.error.HTTPError as e:
        location = e.headers['Location']
    with urllib.request.urlopen(location, timeout=600) as r, open(dest, 'wb') as f:
        f.write(r.read())
    print('saved', dest)
if cmd == 'cancel':
    print(call('POST', f'/repos/{repo}/actions/runs/{rest[0]}/cancel'))
