#!/usr/bin/env python3
"""Build deploy records for the Object Lock audit bucket (APP-11, ADR-004, HC-2).

Usage:
  deploy-record.py app <commit sha> <before sha> <out dir>
      A push to main. Writes one record per environment whose deploy/values-<env>.yaml changed
      between <before sha> and <commit sha>: an application deploy (Argo CD syncs that commit).
  deploy-record.py apply <tf-apply run id> <out dir>
      A finished tf-apply run. Writes a record for prod if its "apply prod" job succeeded: a
      production terraform apply, with who approved it.

Each record is one JSON file, {actor, approver, PR, commit SHA, image digests or plan, env,
timestamp}, named <env>/<UTC time>-<kind>-<short sha>-<run id>-<attempt>.json under <out dir>. The
workflow uploads them to s3://<audit bucket>/deploys/<env>/... Nothing is read back: the role can
only add objects there.

Reads GitHub's API with GH_TOKEN (contents, pull requests and actions: read). Fails rather than
writing a record with missing fields, so a red run shows a deploy that wasn't recorded.
"""
import datetime
import json
import os
import re
import subprocess
import sys

REPO = os.environ["GITHUB_REPOSITORY"]
SERVER = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
VALUES = re.compile(r"^deploy/values-(staging|prod)\.yaml$")
SECTION = re.compile(r"^\s*([a-zA-Z][a-zA-Z0-9-]*):\s*(?:#.*)?$")
INLINE = re.compile(r'^\s*([a-zA-Z][a-zA-Z0-9-]*):\s*\{.*digest:\s*"(sha256:[0-9a-f]{64})"')
DIGEST = re.compile(r'digest:\s*"(sha256:[0-9a-f]{64})"')
APP_COMMIT = re.compile(r"merlion-bank-app commit ([0-9a-f]{7,40})")


def gh(path):
    """GET a GitHub API path (all pages), parsed from JSON."""
    out = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path], check=True, capture_output=True, text=True
    ).stdout
    pages = json.loads(out)
    if pages and isinstance(pages[0], list):
        return [item for page in pages for item in page]
    return pages[0] if len(pages) == 1 else pages


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pipeline():
    return {
        "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
        "run_url": f"{SERVER}/{REPO}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "aws_session": f"ci-{os.environ['GITHUB_RUN_ID']}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}",
    }


def pull_request(sha):
    """The merged PR that produced <sha> on main, with its author, merger and approvers."""
    prs = [p for p in gh(f"repos/{REPO}/commits/{sha}/pulls") if p.get("merged_at")]
    if not prs:
        sys.exit(f"{sha}: no merged pull request found; every change to main should come from one")
    pr = prs[0]
    latest = {}
    for review in gh(f"repos/{REPO}/pulls/{pr['number']}/reviews"):
        if review["state"] in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest[review["user"]["login"]] = review["state"]
    full = gh(f"repos/{REPO}/pulls/{pr['number']}")
    return {
        "number": pr["number"],
        "title": pr["title"],
        "url": pr["html_url"],
        "author": pr["user"]["login"],
        "merged_by": (full.get("merged_by") or {}).get("login"),
        "merged_at": pr["merged_at"],
        "approvers": sorted(u for u, s in latest.items() if s == "APPROVED"),
    }


def images(sha, path):
    """{image: digest} from a values file at <sha>, and the app commit its header names."""
    text = git("show", f"{sha}:{path}")
    # Two layouts, as in the values files:
    #   frontend:                                    accounts: { image: { digest: "sha256:…" } }
    #     image: { digest: "sha256:…" }
    found, section = {}, None
    for line in text.splitlines():
        if (m := INLINE.match(line)) and m.group(1) != "image":
            found[m.group(1)] = m.group(2)
        elif m := SECTION.match(line):
            section = m.group(1)
        elif (m := DIGEST.search(line)) and section:
            found[section] = m.group(1)
    if not found:
        sys.exit(f"{path} at {sha}: no image digests found")
    app = APP_COMMIT.search(text)
    return found, app.group(1) if app else None


def write(out_dir, record):
    env, kind, sha = record["environment"], record["kind"], record["commit"]["sha"]
    p = record["pipeline"]
    name = f"{record['recorded_at'].replace(':', '')}-{kind}-{sha[:7]}-{p['run_id']}-{p['run_attempt']}.json"
    os.makedirs(os.path.join(out_dir, env), exist_ok=True)
    path = os.path.join(out_dir, env, name)
    with open(path, "w") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{env}/{name}")


def app_records(sha, before, out_dir):
    if re.fullmatch(r"0+", before):  # first push of a branch: nothing to compare with
        changed = git("show", "--name-only", "--format=", sha).split()
    else:
        changed = git("diff", "--name-only", before, sha).split()
    envs = sorted({m.group(1) for m in map(VALUES.match, changed) if m})
    if not envs:
        print("No values file changed: nothing to record")
        return
    pr = pull_request(sha)
    for env in envs:
        digests, header_commit = images(sha, f"deploy/values-{env}.yaml")
        # The promotion PR's title names the app commit ("Promote merlion-bank-app <sha> to …"); the
        # values file's header comment isn't updated by every promotion, so it's only a fallback
        title = re.search(r"merlion-bank-app ([0-9a-f]{7,40})", pr["title"])
        app_commit = title.group(1) if title else header_commit
        write(out_dir, {
            "schema": "merlion-deploy-record/v1",
            "kind": "app-deploy",
            "environment": env,
            "recorded_at": now(),
            "commit": {"sha": sha, "url": f"{SERVER}/{REPO}/commit/{sha}"},
            "pull_request": pr,
            "actor": pr["merged_by"],
            "approvers": pr["approvers"],
            "app_commit": app_commit,
            "images": digests,
            "deployed_by": "Argo CD syncs deploy/ on main (ADR-007)",
            "pipeline": pipeline(),
        })


def apply_records(run_id, out_dir):
    run = gh(f"repos/{REPO}/actions/runs/{run_id}")
    if run["head_branch"] != "main":
        print(f"Run {run_id} is on {run['head_branch']}, not main: nothing to record")
        return
    jobs = gh(f"repos/{REPO}/actions/runs/{run_id}/jobs")
    jobs = jobs["jobs"] if isinstance(jobs, dict) else [j for page in jobs for j in page["jobs"]]
    applied = [j for j in jobs if j["name"] == "apply prod" and j["conclusion"] == "success"]
    if not applied:
        print(f"Run {run_id}: apply prod didn't run or didn't succeed, nothing to record")
        return
    approvals = [
        {"user": a["user"]["login"], "state": a["state"], "comment": a.get("comment") or ""}
        for a in gh(f"repos/{REPO}/actions/runs/{run_id}/approvals")
        if any(e.get("name") == "production" for e in a.get("environments", []))
    ]
    approvers = sorted({a["user"] for a in approvals if a["state"] == "approved"})
    if not approvers:
        sys.exit(f"Run {run_id}: apply prod succeeded but no production approval was found")
    sha = run["head_sha"]
    pr = pull_request(sha)
    write(out_dir, {
        "schema": "merlion-deploy-record/v1",
        "kind": "infra-apply",
        "environment": "prod",
        "recorded_at": now(),
        "commit": {"sha": sha, "url": f"{SERVER}/{REPO}/commit/{sha}"},
        "pull_request": pr,
        "actor": run["actor"]["login"],
        "approvers": approvers,
        "production_approvals": approvals,
        "plan": {
            "artifact": f"prod-tfplan-{sha}",
            "apply_run_url": run["html_url"],
            "applied_at": applied[0]["completed_at"],
        },
        "pipeline": pipeline(),
    })


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "app":
        app_records(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) == 4 and sys.argv[1] == "apply":
        apply_records(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
