#!/usr/bin/env bash
# Keycloak password grant is enabled ONLY for the controlled RHOAI demonstration.
set -Eeuo pipefail
DEFAULT_USER=user1
KC_USER="${1:-$DEFAULT_USER}"
[[ "$KC_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid Keycloak user' >&2; exit 2; }
KC_CLIENT="${KC_CLIENT:-mcp-gateway}"
KC_REALM="${KC_REALM:-sso}"
if [[ -z "${KC_URL:-}" ]]; then
  command -v oc >/dev/null || { echo 'Set KC_URL or install oc' >&2; exit 1; }
  KC_URL="$(oc get oauth cluster -o json | python3 -c 'import json,sys; ps=json.load(sys.stdin).get("spec",{}).get("identityProviders",[]); m=[x for x in ps if x.get("name")=="rhbk" and x.get("type")=="OpenID"]; print(m[0]["openID"]["issuer"].rsplit("/realms/",1)[0] if m else "")')"
fi
[[ "$KC_URL" == https://* ]] || { echo 'KC_URL must start with https://' >&2; exit 1; }

echo "[DEBUG] Keycloak URL: ${KC_URL}"
echo "[DEBUG] Realm: ${KC_REALM}"
echo "[DEBUG] Client ID: ${KC_CLIENT}"
echo "[DEBUG] Token endpoint: ${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token"

command -v curl >/dev/null; command -v jq >/dev/null
read -rsp "Keycloak password for ${KC_USER}: " KC_PASSWORD; echo
trap 'unset KC_PASSWORD token response' EXIT
response="$(curl -fsS --max-time 25 "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "client_id=$KC_CLIENT" \
  --data-urlencode "username=$KC_USER" \
  --data-urlencode "password=$KC_PASSWORD")"
unset KC_PASSWORD
token="$(jq -er '.access_token' <<< "$response")"
expires="$(jq -er '.expires_in' <<< "$response")"
if command -v wl-copy >/dev/null; then
  printf '%s' "$token" | wl-copy
  echo 'Access token copied to Wayland clipboard (paste WITHOUT the Bearer prefix).'
elif command -v xclip >/dev/null; then
  printf '%s' "$token" | xclip -selection clipboard
  echo 'Access token copied to X11 clipboard (paste WITHOUT the Bearer prefix).'
else
  echo 'Neither wl-copy nor xclip found. Refusing to print token to stdout; install a clipboard tool.' >&2
  exit 1
fi
printf 'User: %s | Token lifetime: %s seconds (%s hours)\n' "$KC_USER" "$expires" "$((expires/3600))"
