#!/usr/bin/env python3
"""Copy every image digest from one values file to another, changing nothing else.

Usage: copy-digests.py <from values file> <to values file>

Both files keep each image's digest on one line within that image's section, e.g.
    frontend:
      image: { digest: "sha256:…" }
For each image found in <from>, the quoted digest in the same section of <to> is replaced, so the diff
is exactly the changed digests (what the "prod promotion only" check verifies). Images only in <from>
(e.g. loadgenerator, which prod doesn't run) are skipped. Fails if an image's section isn't found
exactly once, or holds more than one digest. Prints how many digests changed.
"""
import re
import sys

# image name -> the key that introduces its digest line (as in merlion-bank-app's update-digests.py)
SECTIONS = {
    "frontend": "frontend", "userservice": "userservice", "contacts": "contacts",
    "ledgerwriter": "ledgerwriter", "balancereader": "balancereader",
    "transactionhistory": "transactionhistory",
    "accounts-db": "accounts", "ledger-db": "ledger",  # under dbInit
    "loadgenerator": "loadgenerator",
}
DIGEST = re.compile(r'(digest:\s*")(sha256:[0-9a-f]{64})(")')


def section_digest_line(lines, key, path):
    """Index of the one line holding the digest in <key>'s section, or None if <key> isn't there."""
    hits = [i for i, l in enumerate(lines) if re.match(rf"\s*{re.escape(key)}:", l)]
    if not hits:
        return None
    if len(hits) > 1:
        sys.exit(f"{path}: expected one '{key}:' line, found {len(hits)}")
    i = hits[0]
    indent = len(lines[i]) - len(lines[i].lstrip())
    section = [i]
    for j in range(i + 1, len(lines)):
        if lines[j].strip() and len(lines[j]) - len(lines[j].lstrip()) <= indent:
            break
        section.append(j)
    found = [j for j in section if DIGEST.search(lines[j])]
    if len(found) != 1:
        sys.exit(f"{path}: expected one digest in the '{key}:' section, found {len(found)}")
    return found[0]


src_path, dst_path = sys.argv[1], sys.argv[2]
src = open(src_path).read().split("\n")
dst = open(dst_path).read().split("\n")

changed = 0
for image, key in SECTIONS.items():
    s = section_digest_line(src, key, src_path)
    if s is None:
        continue
    d = section_digest_line(dst, key, dst_path)
    if d is None:
        print(f"skip {image}: not in {dst_path}")
        continue
    digest = DIGEST.search(src[s]).group(2)
    new = DIGEST.sub(rf"\g<1>{digest}\g<3>", dst[d])
    if new != dst[d]:
        dst[d] = new
        changed += 1

open(dst_path, "w").write("\n".join(dst))
print(f"{changed} digest(s) changed in {dst_path}")
