#!/usr/bin/env python3
"""Check that every given image digest was built by merlion-bank-app's cd workflow on main.

Usage: verify-provenance.py <digest> [<digest> ...]

For each digest, fetch its build provenance attestation from GitHub's attestation store (by digest)
and verify it with Sigstore:
  - the signature is valid and the certificate chains to Sigstore's public root, recorded in its
    transparency log while the certificate was valid;
  - the signer is exactly merlion-bank-app/.github/workflows/cd.yml on refs/heads/main;
  - the signed statement is SLSA build provenance whose subject is this digest.

Nothing is pulled from ECR: an image's digest is the hash of its content, so a signed statement about
the digest covers the image. Exits non-zero if any digest has no valid attestation.

Environment:
  GH_TOKEN                  token that can read merlion-bank-app's attestations (attestations: read)
  SIGSTORE_TRUSTED_ROOT     optional path to a trusted_root.json; default: Sigstore's public root via TUF
"""
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request

from sigstore.models import Bundle, TrustedRoot
from sigstore.verify import Verifier
from sigstore.verify.policy import Identity

APP_REPO = "merlion-trust-bank-sg/merlion-bank-app"
SIGNER = f"https://github.com/{APP_REPO}/.github/workflows/cd.yml@refs/heads/main"
ISSUER = "https://token.actions.githubusercontent.com"
PROVENANCE = "https://slsa.dev/provenance/v1"


def attestations(digest):
    """The digest's attestations from GitHub, retrying a few times on network errors."""
    for attempt in range(1, 4):
        try:
            return _fetch_attestations(digest)
        except (urllib.error.URLError, http.client.HTTPException, json.JSONDecodeError, TimeoutError):
            if attempt == 3:
                raise
            time.sleep(2 * attempt)


def _fetch_attestations(digest):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{APP_REPO}/attestations/{digest}?predicate_type=provenance",
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp).get("attestations", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:  # no attestation for this digest
            return []
        raise


def verified(verifier, digest):
    """True if one of the digest's attestations is valid provenance from cd on main for this digest."""
    policy = Identity(identity=SIGNER, issuer=ISSUER)
    for att in attestations(digest):
        try:
            _, payload = verifier.verify_dsse(Bundle.from_json(json.dumps(att["bundle"])), policy)
        except Exception:  # wrong signer, bad signature, not in the log, ...
            continue
        statement = json.loads(payload)
        subjects = {f"sha256:{s['digest'].get('sha256')}" for s in statement.get("subject", [])}
        if statement.get("predicateType") == PROVENANCE and digest in subjects:
            return True
    return False


def main(digests):
    root = os.environ.get("SIGSTORE_TRUSTED_ROOT")
    verifier = Verifier(trusted_root=TrustedRoot.from_file(root)) if root else Verifier.production()

    unsigned = [d for d in digests if not verified(verifier, d)]
    for d in digests:
        print(f"{'FAIL' if d in unsigned else 'ok  '} {d}")
    if unsigned:
        sys.exit(f"{len(unsigned)} digest(s) have no valid build provenance from {SIGNER}")
    print(f"OK: {len(digests)} digest(s) built and signed by cd on main")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
