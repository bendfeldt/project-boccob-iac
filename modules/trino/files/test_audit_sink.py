"""Unit tests of the audit sink redaction: python3 -I -m unittest discover -s modules/trino/files"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_sink  # noqa: E402

KEY = "3f" * 32


class Redaction(unittest.TestCase):
    def test_subject_key_literal(self):
        q = f"delete from curated.keystore.dim_citizen where business_key = '{KEY}'"
        self.assertEqual(audit_sink.redact(q), "delete from curated.keystore.dim_citizen where business_key = '<redacted>'")

    def test_cpr_with_and_without_dash(self):
        q = "select * from clean.borgerportal.citizens where cpr_number in ('010190-1234', '0101901234')"
        self.assertEqual(audit_sink.redact(q).count("<redacted>"), 2)
        self.assertNotIn("1234", audit_sink.redact(q))

    def test_like_and_execute_using(self):
        q = f"EXECUTE st USING '{KEY}', '%{KEY}%', '311299-0001'"
        out = audit_sink.redact(q)
        self.assertNotIn(KEY, out)
        self.assertNotIn("311299-0001", out)

    def test_ordinary_sql_untouched(self):
        for q in (
            "select count(*) from curated.borgerservice.fact_payment where amount > 1000000",
            "select * from t where id = 20261117 and load_id = '1731830400.123456'",
            "select sha256(x) from t limit 64",
        ):
            self.assertEqual(audit_sink.redact(q), q)

    def test_subset_record(self):
        event = {
            "metadata": {"queryId": "q1", "queryState": "FINISHED", "query": f"select 1 where k = '{KEY}'"},
            "context": {"user": "svc-dagster", "groups": ["data-engineer"]},
            "ioMetadata": {"inputs": []},
            "createTime": "t0",
            "endTime": "t1",
        }
        rec = audit_sink.subset(event)
        self.assertNotIn(KEY, json.dumps(rec))
        self.assertEqual(rec["user"], "svc-dagster")
        self.assertEqual(rec["event"], "completed")


if __name__ == "__main__":
    unittest.main()
