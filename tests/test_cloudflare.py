import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.parse
from unittest.mock import Mock, patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location(
    "configure_cloudflare", Path(__file__).resolve().parents[1] / "scripts/configure-cloudflare.py")
cdn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cdn)


class Response(io.BytesIO):
    def __init__(self, body, headers):
        super().__init__(body)
        self.headers = headers


class CloudflareTests(unittest.TestCase):
    def test_public_host_reuse_avoids_duplicates_and_rejects_insecure_changes(self):
        group = {"remark": "Cloudflare public TLS", "groupId": "existing", "inboundIds": [2],
                 "hosts": ["vpn.example.com:443"], "port": 443, "security": "tls", "sni": "vpn.example.com"}
        api = Mock(return_value=[group])
        self.assertEqual(cdn.ensure_public_host(api, 2, "vpn.example.com", "/path"), "existing")
        api.assert_called_once_with("hosts/list")
        with self.assertRaises(RuntimeError):
            cdn.ensure_public_host(Mock(return_value=[dict(group, allowInsecure=True)]), 2, "vpn.example.com", "/path")
        api = Mock(side_effect=[[], [{"groupId": "new"}]])
        self.assertEqual(cdn.ensure_public_host(api, 2, "vpn.example.com", "/path"), "new")
        self.assertEqual(api.call_args.args[0], "hosts/add")
        self.assertEqual(api.call_args.args[1]["security"], "tls")
        self.assertFalse(api.call_args.args[1]["allowInsecure"])

    def test_toggle_uses_dedicated_api_and_checks_persisted_value(self):
        api = Mock(side_effect=[None, {"enable": False}])
        cdn.set_enabled(api, 1, False)
        self.assertEqual(api.call_args_list[0].args, ("inbounds/setEnable/1", {"enable": False}))
        with self.assertRaises(RuntimeError):
            cdn.set_enabled(Mock(side_effect=[None, {"enable": True}]), 1, False)

    def test_https_waits_for_reload_and_never_skips_certificate_validation(self):
        results = [SimpleNamespace(returncode=60, stdout=""),
                   SimpleNamespace(returncode=0, stdout="varon-cdn-ready\n")]
        with patch.object(cdn.subprocess, "run", side_effect=results) as run, patch.object(cdn.time, "sleep") as sleep:
            cdn.wait_https("vpn.example.com")
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(1)
        self.assertNotIn("--insecure", run.call_args.args[0])

    def test_hostname_rejects_nginx_injection_and_invalid_labels(self):
        for value in ("vpn.example.com", "a-b.example.ru"):
            self.assertTrue(cdn.valid_hostname(value))
        for value in ("localhost", "Example.com", "-a.test", "a..test",
                      "a.test; include /tmp/x", "a.test\nlisten 22;", "a" * 64 + ".test"):
            self.assertFalse(cdn.valid_hostname(value))

    def test_link_roundtrip_uses_verified_tls_and_xhttp_without_vision(self):
        path = "/" + "f" * 36
        link = urllib.parse.urlsplit(cdn.cdn_link("client-id", "vpn.example.com", path))
        query = urllib.parse.parse_qs(link.query)
        self.assertEqual(link.hostname, "vpn.example.com")
        self.assertEqual(link.port, 443)
        self.assertEqual(query["path"], [path])
        self.assertEqual(query["sni"], ["vpn.example.com"])
        self.assertEqual(query["security"], ["tls"])
        self.assertEqual(query["type"], ["xhttp"])
        self.assertEqual(query["mode"], ["packet-up"])
        self.assertNotIn("flow", query)
        self.assertNotIn("allowInsecure", query)

    def test_backend_has_no_public_listener_or_independent_client(self):
        payload = cdn.xhttp_payload("/" + "1" * 36)
        self.assertEqual(payload["listen"], "127.0.0.1")
        self.assertEqual(json.loads(payload["settings"])["clients"], [])
        self.assertEqual(json.loads(payload["streamSettings"])["security"], "none")

    def test_nginx_preserves_path_disables_buffering_and_keeps_acme_http(self):
        config = cdn.web_config("vpn.example.com", "secretPanel", 2053, "/" + "1" * 36)
        self.assertIn("listen 443 ssl http2;", config)
        self.assertIn("proxy_pass http://127.0.0.1:16666;", config)
        self.assertIn("proxy_request_buffering off;", config)
        self.assertIn('Cache-Control "no-store, no-transform"', config)
        self.assertIn("location ^~ /secretPanel/", config)
        self.assertIn("proxy_pass http://127.0.0.1:2053;", config)
        self.assertIn("location ^~ /.well-known/acme-challenge/", cdn.http_config("vpn.example.com"))

    def test_health_requires_cloudflare_header_and_our_origin_body(self):
        cdn.checked_cdn_response(Response(b"varon-cdn-ready\n", {"CF-Ray": "123"}))
        for body, headers in ((b"varon-cdn-ready", {}), (b"wrong origin", {"CF-Ray": "123"})):
            with self.assertRaises(RuntimeError):
                cdn.checked_cdn_response(Response(body, headers))

    def test_actual_core_rejects_public_bind_missing_client_and_vision_flow(self):
        config = {"inbounds": [{"port": 16666, "listen": "127.0.0.1",
                               "settings": {"clients": [{"id": "same-uuid"}]}}]}
        cdn.check_generated(config, "same-uuid")
        for mutation in ("listener", "uuid", "flow", "clients"):
            changed = copy.deepcopy(config)
            inbound = changed["inbounds"][0]
            if mutation == "listener":
                inbound["listen"] = "0.0.0.0"
            elif mutation == "uuid":
                inbound["settings"]["clients"][0]["id"] = "different-uuid"
            elif mutation == "flow":
                inbound["settings"]["clients"][0]["flow"] = "xtls-rprx-vision"
            else:
                inbound["settings"]["clients"] = []
            with self.assertRaises(RuntimeError):
                cdn.check_generated(changed, "same-uuid")


if __name__ == "__main__":
    unittest.main()
