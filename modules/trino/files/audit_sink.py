"""Receives Trino HTTP event listener events on localhost and writes one JSON
line per query event to stdout, where the cluster log pipeline collects it.

Trino (484) has no stdout/file event listener; the http listener is the only
built-in one that needs no external system. AUDIT_FULL_EVENTS=true emits the
complete event instead of the audit subset.
Python standard library only.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FULL = os.environ.get("AUDIT_FULL_EVENTS", "false").lower() == "true"


def subset(event):
    meta = event.get("metadata", {})
    ctx = event.get("context", {})
    io = event.get("ioMetadata", {})
    failure = event.get("failureInfo") or {}
    record = {
        "log_type": "trino-query-audit",
        "event": "completed" if "endTime" in event else "created",
        "query_id": meta.get("queryId"),
        "state": meta.get("queryState"),
        "user": ctx.get("user"),
        "principal": ctx.get("principal"),
        "groups": ctx.get("groups"),
        "source": ctx.get("source"),
        "remote_address": ctx.get("remoteClientAddress"),
        "user_agent": ctx.get("userAgent"),
        "catalog": ctx.get("catalog"),
        "schema": ctx.get("schema"),
        "query_type": ctx.get("queryType"),
        "query": meta.get("query"),
        "create_time": event.get("createTime"),
        "end_time": event.get("endTime"),
        "inputs": [
            {"catalog": i.get("catalogName"), "schema": i.get("schema"), "table": i.get("table"), "columns": i.get("columns")}
            for i in io.get("inputs", [])
        ],
        "output": (
            {k: io["output"].get(k) for k in ("catalogName", "schema", "table")} if io.get("output") else None
        ),
        "error_code": (failure.get("errorCode") or {}).get("name"),
        "failure_type": failure.get("failureType"),
    }
    return {k: v for k, v in record.items() if v is not None}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            event = json.loads(raw)
            out = event if FULL else subset(event)
            sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            self.send_response(204)
        except ValueError:
            self.send_response(400)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("AUDIT_PORT", "8090"))), Handler).serve_forever()
