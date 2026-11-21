"""Receives Trino HTTP event listener events on localhost and writes one JSON
line per query event to stdout, where the cluster log pipeline collects it.

Trino (484) has no stdout/file event listener; the http listener is the only
built-in one that needs no external system. AUDIT_FULL_EVENTS=true emits the
complete event instead of the audit subset.

Redaction (GDPR: the audit archive is WORM and can never be erased): string
literals that look like a pseudonymised subject key (64 hex characters) or a
CPR number (DDMMYY-NNNN / DDMMYYNNNN) are replaced in the query text before
the record is written, so neither an erasure nor an ad-hoc lookup of a person
puts the identifier into the archive. The query shape stays auditable. With
AUDIT_FULL_EVENTS=true every string field of the event is redacted the same way
(preparedQuery, failureInfo messages, plans, ...; audit N-10).
Python standard library only.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FULL = os.environ.get("AUDIT_FULL_EVENTS", "false").lower() == "true"
REDACTED = "<redacted>"
# 64 hex characters (HMAC-SHA256 pseudonym) and CPR-shaped numbers, anywhere in
# the text: inside quotes, in LIKE patterns, in EXECUTE ... USING parameters
_PATTERNS = (
    re.compile(r"(?<![0-9A-Za-z])[0-9A-Fa-f]{64}(?![0-9A-Za-z])"),
    re.compile(r"(?<![0-9])[0-3][0-9][01][0-9]{3}-?[0-9]{4}(?![0-9])"),
)


def redact(text):
    if not text:
        return text
    for pattern in _PATTERNS:
        text = pattern.sub(REDACTED, text)
    return text


def redact_all(value):
    """Redact every string anywhere in a structure (full-event mode: the query, the
    prepared query, failure messages, plans and any other field can echo literals)."""
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [redact_all(v) for v in value]
    if isinstance(value, dict):
        return {k: redact_all(v) for k, v in value.items()}
    return value


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
        "query": redact(meta.get("query")),
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
            if FULL:
                out = redact_all(event)
            else:
                out = subset(event)
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
