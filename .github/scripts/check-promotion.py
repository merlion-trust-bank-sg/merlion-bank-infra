#!/usr/bin/env python3
"""Check that a promotion PR changes nothing but image digests in one values file.

Usage: check-promotion.py <base ref> <head ref> <values file> [--same-as <file>] [--digests-out <file>]

  --same-as <file>       every digest the PR sets must also appear in <file> at <base ref> (prod: the
                         staging values file, so prod only gets digests staging already runs)
  --digests-out <file>   write the digests the PR sets, one per line, for verify-provenance.py

Compares <head ref> (the PR's commit) with <base ref> (main). Only reads them with git diff / git show:
nothing from the PR is ever run, so it's safe under pull_request_target, where this script and its
workflow come from main and a PR can't change the check it's judged by.

Passes only if the PR's sole changed file is <values file>, with the same number of lines, and every
line that differs differs only in a sha256 digest. Anything else (a new key, a changed registry, a
second file) fails, so a promotion PR is never more than a digest bump.
"""
import argparse
import re
import subprocess
import sys

p = argparse.ArgumentParser()
p.add_argument("base")
p.add_argument("head")
p.add_argument("values")
p.add_argument("--same-as")
p.add_argument("--digests-out")
args = p.parse_args()
base, head, values = args.base, args.head, args.values
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

changed = []
for n, (a, b) in enumerate(zip(old, new), start=1):
    if a == b:
        continue
    if DIGEST.sub("<digest>", a) != DIGEST.sub("<digest>", b) or not DIGEST.search(b):
        sys.exit(f"{values}:{n}: changes more than a digest:\n  - {a}\n  + {b}")
    changed += DIGEST.findall(b)

if args.same_as:
    allowed = set(DIGEST.findall(git("show", f"{base}:{args.same_as}")))
    other = sorted(set(changed) - allowed)
    if other:
        sys.exit(f"Not in {args.same_as} on main, so never ran there: {', '.join(other)}")

if args.digests_out:
    with open(args.digests_out, "w") as f:
        f.write("".join(f"{d}\n" for d in sorted(set(changed))))

same = f", all as in {args.same_as}" if args.same_as else ""
print(f"OK: {len(changed)} digest(s) changed in {values}, nothing else{same}")
