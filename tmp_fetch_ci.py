#!/usr/bin/env python3
import urllib.request, urllib.error, json, os

TOKEN=os.env...N", "")
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "bugbot"
}
BASE = "https://api.github.com/repos/Eth4ck1e/prusaslicer-xpra"

def gh_get(path):
    url = f"{BASE}/{path}"
    req = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:500]}

# Run details
run = gh_get("actions/runs/27925660123")
print("RUN:", json.dumps({k:run.get(k) for k in ["head_sha","head_branch","conclusion","status","event","display_title"]}, indent=2))
sha = run.get("head_sha","")

# Jobs + logs
jobs = gh_get(f"actions/runs/27925660123/jobs")
for j in jobs.get("jobs",[]):
    print(f"JOB: {j['name']} status={j['status']} conclusion={j.get('conclusion','?')}")
    for s in j.get("steps",[]):
        print(f"  STEP: {s['name']} status={s['status']} conclusion={s.get('conclusion','?')}")
    if j.get("conclusion") != "success":
        log_url = f"{BASE}/actions/jobs/{j['id']}/logs"
        lreq = urllib.request.Request(log_url, headers=HEADERS)
        try:
            with urllib.request.urlopen(lreq) as r:
                lines = r.read().decode().splitlines()
                for line in lines[-200:]:
                    print(f"  LOG: {line}")
        except urllib.error.HTTPError as e:
            print(f"  LOG_ERR: HTTP {e.code}")

# Check annotations
if sha:
    crs = gh_get(f"commits/{sha}/check-runs")
    for cr in crs.get("check_runs",[]):
        anno = gh_get(f"check-runs/{cr['id']}/annotations")
        if isinstance(anno,list) and anno:
            print(f"ANNOTATIONS for {cr['name']}:")
            for a in anno:
                print(f"  [{a.get('annotation_level','?')}] {a.get('path','?')}:L{a.get('start_line','?')} {a.get('message','')[:300]}")

# Recent commits
print("COMMITS:")
for c in gh_get("commits?per_page=10"):
    print(f"  {c['sha'][:8]} {c['commit']['message'].split(chr(10))[0][:80]}")