import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock
import urllib.parse

spec = importlib.util.spec_from_file_location(
    "manage_cloudflare", Path(__file__).resolve().parents[1] / "scripts/manage-cloudflare.py")
users = importlib.util.module_from_spec(spec)
spec.loader.exec_module(users)


class CloudflareUsersTests(unittest.TestCase):
    def setUp(self):
        self.route = {"tag": "cloudflare-trojan-ws", "port": 16668, "protocol": "trojan",
                      "path": "/" + "a" * 36, "label": "Trojan-WS"}
        self.record = {"id": 12, "uuid": "existing-uuid", "password": "existing-password",
                       "email": "old", "subId": "existing-sub", "flow": "", "totalGB": 123}

    def test_names_allow_requested_case_but_reject_duplicates_and_file_paths(self):
        self.assertTrue(users.valid_names(["Varon", "Nargiza", "Nekite"]))
        for names in ([], ["one", "ONE"], ["../other"], ["name/evil"], ["a\nb"], ["x" * 33]):
            self.assertFalse(users.valid_names(names))

    def test_rename_preserves_uuid_password_subscription_and_quota(self):
        self.record["allowedIPs"] = ""
        payload = users.update_payload(self.record, "Owner")
        self.assertEqual(payload["id"], self.record["uuid"])
        self.assertEqual(payload["password"], self.record["password"])
        self.assertEqual(payload["subId"], self.record["subId"])
        self.assertEqual(payload["totalGB"], 123)
        self.assertEqual(payload["flow"], "")
        self.assertEqual(self.record["email"], "old")
        self.assertNotIn("uuid", payload)
        self.assertNotIn("allowedIPs", payload)

    def test_new_users_have_independent_credentials(self):
        one, two = users.new_client("One"), users.new_client("Two")
        for key in ("id", "password", "subId"):
            self.assertNotEqual(one[key], two[key])
        self.assertEqual(one["flow"], "")
        self.assertEqual(one["expiryTime"], 0)

    def test_trojan_link_uses_password_and_http11_with_verified_tls(self):
        link = urllib.parse.urlsplit(users.ws_link(self.record, "vpn.example.com", self.route))
        query = urllib.parse.parse_qs(link.query)
        self.assertEqual(link.scheme, "trojan")
        self.assertEqual(link.username, self.record["password"])
        self.assertEqual(query["alpn"], ["http/1.1"])
        self.assertEqual(query["security"], ["tls"])
        self.assertEqual(query["path"], [self.route["path"]])
        self.assertNotIn("flow", query)
        self.assertNotIn("allowInsecure", query)

    def test_existing_routes_are_reused_and_mismatched_paths_are_rejected(self):
        inbound = users.ws_payload(self.route)
        inbound["id"] = 3
        api = Mock(return_value=[inbound])
        self.assertEqual(users.ensure_route(api, self.route), 3)
        api.assert_called_once_with("inbounds/list")
        changed = copy.deepcopy(inbound)
        stream = json.loads(changed["streamSettings"])
        stream["wsSettings"]["path"] = "/other"
        changed["streamSettings"] = json.dumps(stream)
        with self.assertRaises(RuntimeError):
            users.ensure_route(Mock(return_value=[changed]), self.route)

    def test_rerender_keeps_websocket_routes_and_upgrade_headers(self):
        config = users.cdn.web_config("vpn.example.com", "panel", 2053, "/xhttp", [self.route])
        self.assertIn("location = " + self.route["path"], config)
        self.assertIn("proxy_pass http://127.0.0.1:16668;", config)
        self.assertIn("proxy_set_header Upgrade $http_upgrade;", config)
        core = {"inbounds": [{"port": 16666, "listen": "127.0.0.1",
                             "settings": {"clients": [{"id": "one"}, {"id": "two"}]}}]}
        users.cdn.check_generated(core, ["one", "two"])
        with self.assertRaises(RuntimeError):
            users.cdn.check_generated(core, ["one", "missing"])


if __name__ == "__main__":
    unittest.main()
