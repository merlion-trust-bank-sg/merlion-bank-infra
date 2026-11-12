#!/usr/bin/env python3
"""Check that a promotion PR changes nothing but image digests in one values file.

Usage: check-promotion.py <base ref> <values file>

Passes only if the PR's sole changed file is <values file>, with the same number of lines, and every
line that differs differs only in a sha256 digest. Anything else (a new key, a changed registry, a
second file) fails, so the promotion App can never merge more than a digest bump.
"""
import re
import subprocess
import sys

base, values = sys.argv[1], sys.argv[2]
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


files = git("diff", "--name-only", f"{base}...HEAD").split()
if files != [values]:
    sys.exit(f"A promotion may change only {values}; this PR changes: {', '.join(files) or 'nothing'}")

old = git("show", f"{base}:{values}").split("\n")
new = git("show", f"HEAD:{values}").split("\n")
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
