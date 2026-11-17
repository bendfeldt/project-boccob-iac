"""Minimal Trino REST client for the platform scripts (standard library only).

  TRINO_URL   https://trino.<base_domain>[:port]
  TRINO_CA    CA bundle for TLS verification
  TRINO_USER  user name
  TRINO_PASSWORD or TRINO_TOKEN   basic auth (service account) or bearer JWT (Keycloak)
  TRINO_RESOLVE  optional "<ip>": connect to this address instead of resolving the host

  python3 -I trino_query.py "<sql>"   -> one JSON array per row on stdout; exit 1 + message on error
"""

import base64
import http.client
import json
import os
import socket
import ssl
import sys
import urllib.parse


def main(sql):
    url = urllib.parse.urlsplit(os.environ["TRINO_URL"])
    ctx = ssl.create_default_context(cafile=os.environ["TRINO_CA"])
    user = os.environ["TRINO_USER"]
    headers = {"X-Trino-User": user, "X-Trino-Source": "boccob-platform-scripts"}
    if os.environ.get("TRINO_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["TRINO_TOKEN"]
    else:
        cred = f"{user}:{os.environ['TRINO_PASSWORD']}".encode()
        headers["Authorization"] = "Basic " + base64.b64encode(cred).decode()

    def request(method, path, body=None):
        conn = http.client.HTTPSConnection(url.hostname, url.port or 443, context=ctx, timeout=300)
        if os.environ.get("TRINO_RESOLVE"):  # connect elsewhere, keep SNI + Host = the public name
            target = os.environ["TRINO_RESOLVE"]
            conn._create_connection = lambda addr, *a, **k: socket.create_connection((target, addr[1]), *a, **k)
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            print(f"ERROR: HTTP {resp.status} {data[:300].decode(errors='replace')}")
            sys.exit(1)
        return json.loads(data)

    r = request("POST", "/v1/statement", sql.encode())
    while True:
        for row in r.get("data", []):
            print(json.dumps(row, default=str))
        if "error" in r:
            err = r["error"]
            print(f"ERROR: {err.get('errorName')}: {err.get('message', '')[:400]}")
            sys.exit(1)
        if "nextUri" not in r:
            return 0
        r = request("GET", urllib.parse.urlsplit(r["nextUri"]).path)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
