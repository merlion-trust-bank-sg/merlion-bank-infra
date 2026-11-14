#!/usr/bin/env python3
"""Check that a promotion PR changes nothing but image digests in one values file.

Usage: check-promotion.py <base ref> <head ref> <values file>

Compares <head ref> (the PR's commit) with <base ref> (main). Only reads them with git diff / git show:
nothing from the PR is ever run, so it's safe under pull_request_target, where this script and its
workflow come from main and a PR can't change the check it's judged by.

Passes only if the PR's sole changed file is <values file>, with the same number of lines, and every
line that differs differs only in a sha256 digest. Anything else (a new key, a changed registry, a
second file) fails, so the promotion App can never merge more than a digest bump.
"""
import re
import subprocess
import sys

base, head, values = sys.argv[1], sys.argv[2], sys.argv[3]
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


files = git("diff", "--name-only", f"{base}...{head}").split()
if files != [values]:
    sys.exit(f"A promotion may change only {values}; this PR changes: {', '.join(files) or 'nothing'}")

old = git("show", f"{base}:{values}").split("\n")
new = git("show", f"{head}:{values}").split("\n")
if len(old) != len(new):
    sys.exit(f"{values}: lines added or removed ({len(old)} -> {len(new)}); only digests may change")

changed = 0
for n, (a, b) in enumerate(zip(old, new), start=1):
    if a == b:
        continue
    if DIGEST.sub("<digest>", a) != DIGEST.sub("<digest>", b) or not DIGEST.search(b):
        sys.exit(f"{values}:{n}: changes more than a digest:\n  - {a}\n  + {b}")
    changed += 1

print(f"OK: {changed} digest(s) changed in {values}, nothing else")
