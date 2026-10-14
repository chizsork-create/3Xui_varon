import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.parse

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "bootstrap-direct.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_direct", SCRIPT)
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.payload = bootstrap.direct_payload(8443, "www.example.com", "private", "public", "aabb")
        self.payload["id"] = 1

    def test_roundtrip_string_and_object_api_responses(self):
        for decoded in (False, True):
            item = dict(self.payload)
            if decoded:
                item["settings"] = json.loads(item["settings"])
                item["streamSettings"] = json.loads(item["streamSettings"])
            selected = bootstrap.select_existing([item], 8443, 1)
            link = urllib.parse.urlsplit(bootstrap.make_link(selected, "192.0.2.1"))
            query = urllib.parse.parse_qs(link.query)
            self.assertEqual(link.hostname, "192.0.2.1")
            self.assertEqual(query["flow"], ["xtls-rprx-vision"])
            self.assertEqual(query["pbk"], ["public"])
            self.assertEqual(query["security"], ["reality"])
            self.assertNotIn("private", bootstrap.make_link(selected, "192.0.2.1"))

    def test_repeated_selection_keeps_uuid_and_link(self):
        first = bootstrap.make_link(bootstrap.select_existing([self.payload], 8443), "192.0.2.1")
        again = bootstrap.make_link(bootstrap.select_existing([self.payload], 8443, 1), "192.0.2.1")
        self.assertEqual(first, again)

    def test_unrelated_inbound_and_missing_recorded_client_are_rejected(self):
        item = dict(self.payload, protocol="trojan")
        with self.assertRaises(RuntimeError):
            bootstrap.select_existing([item], 8443)
        with self.assertRaises(RuntimeError):
            bootstrap.select_existing([], 8443, 1)
        with self.assertRaises(RuntimeError):
            bootstrap.select_existing([self.payload], 8443, 2)

    def test_raw_alias_is_rejected_instead_of_losing_vision(self):
        self.payload["streamSettings"] = json.loads(self.payload["streamSettings"])
        self.payload["streamSettings"]["network"] = "raw"
        with self.assertRaises(RuntimeError):
            bootstrap.select_existing([self.payload], 8443)

    def test_atomic_secret_write_is_private_and_replaceable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state" / "secret"
            bootstrap.write_private(path, "one")
            bootstrap.write_private(path, "two")
            self.assertEqual(path.read_text(), "two")
            if os.name != "nt":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_installer_checksum_is_valid_hex_digest(self):
        self.assertRegex(bootstrap.INSTALLER_SHA256, r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
