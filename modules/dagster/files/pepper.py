"""Creates the pseudonymisation pepper in OpenBao exactly once.

Writes kv/<path> with check-and-set 0: OpenBao refuses the write when the
secret already exists, so an existing pepper is never replaced (the policy of
this Job additionally grants `create` only, not `update`). The value is
generated here and never printed. Python standard library only.
"""

import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.request

CTX = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE", "/etc/platform-ca/ca.crt"))
BAO = os.environ["OPENBAO_URL"].rstrip("/")
MOUNT = os.environ.get("OPENBAO_KV_MOUNT", "kv")
PATH = os.environ["PEPPER_KV_PATH"]


def call(method, url, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main():
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
        jwt = f.read().strip()
    code, body = call("POST", f"{BAO}/v1/auth/kubernetes/login", {"role": os.environ["OPENBAO_ROLE"], "jwt": jwt})
    if code != 200:
        print(f"OpenBao login failed: {code}")
        return 1
    token = body["auth"]["client_token"]
    pepper = secrets.token_urlsafe(48)  # 64 characters
    code, body = call("POST", f"{BAO}/v1/{MOUNT}/data/{PATH}", {"options": {"cas": 0}, "data": {"pepper": pepper}}, token)
    if code in (200, 204):
        print(f"pseudonym pepper created at {MOUNT}/{PATH} (version 1) - back it up now (docs/data-plane.md)")
        return 0
    # refused: either it exists (cas mismatch / create-only policy) or something is wrong
    meta_code, meta = call("GET", f"{BAO}/v1/{MOUNT}/metadata/{PATH}", token=token)
    if meta_code == 200:
        print(f"pseudonym pepper already exists at {MOUNT}/{PATH} (version {meta['data'].get('current_version')}): left unchanged")
        return 0
    print(f"could not create the pepper: write {code} {' '.join(body.get('errors', []))}, metadata {meta_code}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
