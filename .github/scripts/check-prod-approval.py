#!/usr/bin/env python3
"""Check that a prod promotion PR is approved by someone other than whoever ran promote-prod.

Usage: check-prod-approval.py <head ref>
Environment: GH_TOKEN (actions: read, pull-requests: read), GITHUB_REPOSITORY, PR, HEAD_SHA, HEAD_REF

GitHub's own rules can't express this: the promotion PR is opened and pushed by the promotion App,
so "the last pusher can't approve" compares approvers with the App, not with the person who clicked
Promote to prod. So this check:
  1. reads the promote-prod run that made the PR's head commit (its "Promotion-run: <id>" trailer;
     only the App can push promote/prod, and if someone else pushed, GitHub already stops them
     approving their own push);
  2. confirms that run is promote-prod.yml, started by hand on main in this repo, and takes who
     started it (and who re-ran it, if anyone);
  3. passes only if someone else, a person, has approved the PR's current head commit and hasn't
     since requested changes.
It re-runs whenever a review is submitted or dismissed (promotion-review.yml).
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

PROMOTE_WORKFLOW = ".github/workflows/promote-prod.yml"
BRANCH = "promote/prod"


def api(path):
    """GET a GitHub API path, retrying network errors."""
    req = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt == 3:
                raise
            time.sleep(2 * attempt)


def commit_message(ref):
    return subprocess.run(["git", "show", "-s", "--format=%B", ref], check=True, capture_output=True,
                          text=True).stdout


def promotion_run_id(message):
    ids = re.findall(r"^Promotion-run:\s*(\d+)\s*$", message, re.MULTILINE)
    return ids[-1] if ids else None


def runners(repo, run_id):
    """Who started (and re-ran) the promote-prod run, after checking it really is one."""
    run = api(f"repos/{repo}/actions/runs/{run_id}")
    path = run.get("path", "").split("@")[0]
    if (run.get("repository", {}).get("full_name") != repo or path != PROMOTE_WORKFLOW
            or run.get("event") != "workflow_dispatch" or run.get("head_branch") != "main"):
        sys.exit(f"Run {run_id} isn't a promote-prod run started by hand on main; can't tell who promoted")
    return {u["login"] for u in (run.get("actor"), run.get("triggering_actor")) if u}


def approvers(repo, pr, head_sha):
    """People whose latest review approves the current head commit."""
    latest = {}
    for r in api(f"repos/{repo}/pulls/{pr}/reviews?per_page=100"):
        if r["state"] == "COMMENTED":  # a comment doesn't change an approval
            continue
        latest[r["user"]["login"]] = r
    return {
        login for login, r in latest.items()
        if r["state"] == "APPROVED" and r.get("commit_id") == head_sha and r["user"].get("type") == "User"
    }


def main(head_ref):
    repo, pr, head_sha = os.environ["GITHUB_REPOSITORY"], os.environ["PR"], os.environ["HEAD_SHA"]
    if os.environ.get("HEAD_REF") != BRANCH:
        sys.exit(f"A prod promotion must come from {BRANCH} (Actions -> promote-prod -> Run workflow)")

    run_id = promotion_run_id(commit_message(head_ref))
    if not run_id:
        sys.exit("The head commit has no Promotion-run trailer; open prod promotions with promote-prod")

    ran_it = runners(repo, run_id)
    others = approvers(repo, pr, head_sha) - ran_it
    if not others:
        sys.exit(f"Needs an approval of {head_sha[:7]} from someone other than {', '.join(sorted(ran_it))} "
                 f"(who ran promote-prod run {run_id}). This check re-runs when a review is submitted.")
    print(f"OK: approved by {', '.join(sorted(others))}; promote-prod run {run_id} was run by "
          f"{', '.join(sorted(ran_it))}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "HEAD")
