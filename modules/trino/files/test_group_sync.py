"""Unit tests of the Keycloak -> Trino group sync (no network)."""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["STATIC_GROUPS"] = '{"data-engineer": ["svc-dagster"], "lakehouse-service": ["svc-dagster"]}'
os.environ["STATIC_ONLY_GROUPS"] = "lakehouse-service"
os.environ.update(KEYCLOAK_URL="https://kc", KEYCLOAK_REALM="r", KEYCLOAK_CLIENT_ID="c", KEYCLOAK_CLIENT_SECRET="s")
import group_sync  # noqa: E402

GROUPS = [{"id": "1", "name": "data-engineer"}, {"id": "2", "name": "lakehouse-service"}, {"id": "3", "name": "other"}]
MEMBERS = {"1": [{"username": "erik"}], "2": [{"username": "mallory"}], "3": [{"username": "x"}]}


def fake_get(ctx, url, token=None, form=None):
    if url.endswith("/token"):
        return {"access_token": "t"}
    if "/members" in url:
        return MEMBERS[url.split("/groups/")[1].split("/")[0]]
    return GROUPS


class GroupSync(unittest.TestCase):
    def test_static_only_group_never_from_keycloak(self):
        with mock.patch.object(group_sync, "get", fake_get), mock.patch.dict(os.environ, {"GROUP_NAMES": ""}):
            groups = group_sync.merged(group_sync.fetch(None))
        self.assertEqual(groups["lakehouse-service"], {"svc-dagster"})
        self.assertEqual(groups["data-engineer"], {"erik", "svc-dagster"})

    def test_render(self):
        self.assertEqual(group_sync.render({"b": {"y", "x"}, "a": set()}), "b:x,y\n")


if __name__ == "__main__":
    unittest.main()
