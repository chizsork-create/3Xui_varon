#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/state.sh
source "$ROOT_DIR/lib/state.sh"
# shellcheck source=../lib/clients.sh
source "$ROOT_DIR/lib/clients.sh"
# shellcheck source=../lib/xui-api.sh
source "$ROOT_DIR/lib/xui-api.sh"
# shellcheck source=../lib/inbounds.sh
source "$ROOT_DIR/lib/inbounds.sh"

vless=$(build_vless_client_json '11111111-1111-4111-8111-111111111111' 'varon' 'sub123' 42)
trojan=$(build_trojan_client_json 'secret' 'varon' 'sub123' 42)
shared=$(build_shared_client_json '11111111-1111-4111-8111-111111111111' 'secret' 'varon' 'sub123' 42)
payload=$(build_client_create_payload "$shared" 3 5 7)

jq --exit-status -e '
  .id == "11111111-1111-4111-8111-111111111111" and
  .email == "varon" and .subId == "sub123" and
  .enable == true and .created_at == 42 and .flow == ""
' <<<"$vless" >/dev/null
jq --exit-status -e '
  .password == "secret" and .email == "varon" and
  .subId == "sub123" and .enable == true and .comment == ""
' <<<"$trojan" >/dev/null
jq --exit-status -e '
  .client.id == "11111111-1111-4111-8111-111111111111" and
  .client.password == "secret" and .client.subId == "sub123" and
  .inboundIds == [3, 5, 7]
' <<<"$payload" >/dev/null
[[ $(normalize_web_base_path '/varon/') == 'varon' ]]
[[ $(xui_panel_url 'vpn.example.test' 'varon') == 'https://vpn.example.test/varon' ]]
[[ $(xui_api_url 'vpn.example.test' 'varon' '/clients/add') == 'https://vpn.example.test/varon/panel/api/clients/add' ]]
xui_success_response <<<'{"success":true}'
if xui_success_response <<<'{"success":false}'; then
    printf 'A failed API response was accepted\n' >&2
    exit 1
fi

reality=$(build_reality_inbound_payload 'Reality' 'reality-first' 8443 'reality.example.test' 'www.cloudflare.com:443' 'private-key' 'a1b2c3d4')
xhttp=$(build_xhttp_inbound_payload 'XHTTP' 'xhttp-first' '/run/3xui-varon/xhttp.sock' 'vpn.example.test' 'abcdefgh' '/etc/letsencrypt/live/vpn/fullchain.pem' '/etc/letsencrypt/live/vpn/privkey.pem')
trojan=$(build_trojan_grpc_inbound_payload 'Trojan gRPC' 'trojan-first' 1443 'trojanpath')
tls_hosts=$(build_host_group_payload 'Public TLS' 'vpn.example.test' tls 2 3)
reality_hosts=$(build_host_group_payload 'Public Reality' 'reality.example.test' same 1)

jq --exit-status -e '.protocol == "vless" and .port == 8443 and (.streamSettings | fromjson | .security == "reality") and (.streamSettings | fromjson | .tcpSettings.acceptProxyProtocol == true)' <<<"$reality" >/dev/null
jq --exit-status -e '.listen == "/run/3xui-varon/xhttp.sock,0660" and .port == 0 and (.streamSettings | fromjson | .network == "xhttp") and (.streamSettings | fromjson | .xhttpSettings.mode == "packet-up")' <<<"$xhttp" >/dev/null
jq --exit-status -e '.protocol == "trojan" and .listen == "127.0.0.1" and (.streamSettings | fromjson | .grpcSettings.serviceName == "trojanpath")' <<<"$trojan" >/dev/null
jq --exit-status -e '.inboundIds == [2, 3] and .port == 443 and .security == "tls" and .sni == "vpn.example.test"' <<<"$tls_hosts" >/dev/null
jq --exit-status -e '.inboundIds == [1] and .security == "same"' <<<"$reality_hosts" >/dev/null

printf 'client JSON tests passed\n'
