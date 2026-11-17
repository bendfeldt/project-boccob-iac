"""Keeps the Trino file group provider in sync with Keycloak group membership.

Trino (484) only ships `file` and `ldap` group providers and cannot read groups
from OAuth2 token claims. This sidecar polls the Keycloak admin API with a
service account (client credentials, realm-management roles view-users +
query-groups) and rewrites the group file atomically; Trino re-reads it within
`file.refresh-period`.

Static members (service accounts that do not exist in Keycloak) come from
STATIC_GROUPS (JSON: group => [users]). On errors the previous file is kept.
`--once-static` writes only the static members (init container).
Python standard library only.
"""

import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request

GROUP_FILE = os.environ.get("GROUP_FILE", "/groups/group.db")
STATIC = json.loads(os.environ.get("STATIC_GROUPS", "{}"))
INTERVAL = int(os.environ.get("SYNC_INTERVAL_SECONDS", "30"))


def log(msg):
    print(json.dumps({"component": "trino-group-sync", "message": msg}), flush=True)


def render(groups):
    lines = [f"{g}:{','.join(sorted(m))}" for g, m in sorted(groups.items()) if m]
    return "\n".join(lines) + "\n"


def write(content):
    tmp = GROUP_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, GROUP_FILE)


def get(ctx, url, token=None, form=None):
    data = urllib.parse.urlencode(form).encode() if form else None
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
        return json.loads(resp.read())


def fetch(ctx):
    base = os.environ["KEYCLOAK_URL"].rstrip("/")
    realm = os.environ["KEYCLOAK_REALM"]
    wanted = set(filter(None, os.environ.get("GROUP_NAMES", "").split(",")))
    token = get(
        ctx,
        f"{base}/realms/{realm}/protocol/openid-connect/token",
        form={
            "grant_type": "client_credentials",
            "scope": "kc-admin-api",
            "client_id": os.environ["KEYCLOAK_CLIENT_ID"],
            "client_secret": os.environ["KEYCLOAK_CLIENT_SECRET"],
        },
    )["access_token"]
    admin = f"{base}/admin/realms/{realm}"
    groups = {}
    for group in get(ctx, f"{admin}/groups?max=1000", token):
        name = group["name"]
        if wanted and name not in wanted:
            continue
        members, first = set(), 0
        while True:
            page = get(ctx, f"{admin}/groups/{group['id']}/members?first={first}&max=500", token)
            members.update(u["username"] for u in page if u.get("enabled", True))
            if len(page) < 500:
                break
            first += 500
        groups[name] = members
    return groups


def merged(groups):
    out = {g: set(m) for g, m in groups.items()}
    for g, members in STATIC.items():
        out.setdefault(g, set()).update(members)
    return out


def main():
    if "--once-static" in sys.argv:
        write(render(merged({})))
        return 0
    ctx = ssl.create_default_context(cafile=os.environ.get("CA_BUNDLE", "/etc/platform-ca/ca.crt"))
    last, failing = None, False
    while True:
        try:
            content = render(merged(fetch(ctx)))
            if content != last:
                write(content)
                last = content
                log(f"group file updated: {content.count(chr(10))} groups")
            if failing:
                log("Keycloak reachable again")
            failing = False
        except Exception as e:  # keep the last known membership
            if not failing:
                log(f"sync failed, keeping the previous group file: {e.__class__.__name__}: {e}")
            failing = True
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
