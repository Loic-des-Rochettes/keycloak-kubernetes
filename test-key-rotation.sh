#!/usr/bin/env bash
# Rotation of the realm signing key, as seen by Envoy, which keeps the JWKS of
# Keycloak in cache for 5 minutes (remoteJWKS cacheDuration).
#   1. Naive rotation: a new key with the highest priority signs at once, and
#      Envoy rejects its tokens until it fetches the JWKS again.
#   2. Safe rotation: the new key is published first with a lower priority,
#      Envoy fetches it, then it takes over. No token is rejected.
# Takes about 6 minutes.
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib.sh

JWKS_CACHE_SECONDS=300
REPORTING_JOB_SECRET="$(secret keycloak demo-realm-secrets reporting-job-secret)"
REALM_ID="$(c -H "Authorization: Bearer $(admin_token)" "$KC_ADMIN/admin/realms/demo" | jq -r .id)"

kid() { # kid of the JWT header
  python3 -c 'import sys,json,base64; h=sys.argv[1].split(".")[0]; print(json.loads(base64.urlsafe_b64decode(h+"="*(-len(h)%4)))["kid"])' "$1"
}
api_status() { http_code -H "Authorization: Bearer $(client_token reporting-job "$REPORTING_JOB_SECRET")" "$API/items"; }
max_priority() {
  c -H "Authorization: Bearer $(admin_token)" "$KC_ADMIN/admin/realms/demo/keys" |
    jq '[.keys[] | select(.algorithm == "RS256" and .status == "ACTIVE") | .providerPriority] | max'
}
add_key() { # name priority -> prints the component id
  local location
  location="$(c -D - -o /dev/null -H "Authorization: Bearer $(admin_token)" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\",\"providerId\":\"rsa-generated\",\"providerType\":\"org.keycloak.keys.KeyProvider\",\"parentId\":\"$REALM_ID\",\"config\":{\"priority\":[\"$2\"],\"enabled\":[\"true\"],\"active\":[\"true\"],\"keySize\":[\"2048\"],\"algorithm\":[\"RS256\"]}}" \
    "$KC_ADMIN/admin/realms/demo/components" | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')"
  basename "$location"
}
set_priority() { # component id, priority
  local token component
  token="$(admin_token)"
  component="$(c -H "Authorization: Bearer $token" "$KC_ADMIN/admin/realms/demo/components/$1" |
    jq --arg p "$2" '.config.priority = [$p]')"
  http_code -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "$component" "$KC_ADMIN/admin/realms/demo/components/$1"
}
delete_key() { http_code -X DELETE -H "Authorization: Bearer $(admin_token)" "$KC_ADMIN/admin/realms/demo/components/$1"; }
signing_kid() { kid "$(client_token reporting-job "$REPORTING_JOB_SECRET")"; }

section "Before the rotation"
check "API call with the current key: 200" 200 "$(api_status)"
OLD_KID="$(signing_kid)"

section "Naive rotation: the new key signs at once"
NAIVE="$(add_key "rotation-naive-$(date +%s)" $(($(max_priority) + 10)))"
check "New key used for signing" true "$([ "$(signing_kid)" != "$OLD_KID" ] && echo true)"
check "Envoy rejects tokens signed with it: 401" 401 "$(api_status)"
check "Key removed" 204 "$(delete_key "$NAIVE")"
check "Previous key signs again, API call: 200" 200 "$(api_status)"

section "Safe rotation: publish first, sign later"
SAFE="$(add_key "rotation-$(date +%s)" $(($(max_priority) - 10)))"
SAFE_KID="$(c -H "Authorization: Bearer $(admin_token)" "$KC_ADMIN/admin/realms/demo/keys" |
  jq -r --arg id "$SAFE" '.keys[] | select(.providerId == $id) | .kid')"
check "New key published in the JWKS" true \
  "$(c "$KC/realms/demo/protocol/openid-connect/certs" | jq --arg k "$SAFE_KID" 'any(.keys[]; .kid == $k)')"
check "Previous key still signs" "$OLD_KID" "$(signing_kid)"
echo "  waiting $((JWKS_CACHE_SECONDS + 10)) seconds for the JWKS cache of Envoy to expire..."
sleep $((JWKS_CACHE_SECONDS + 10))
check "API call (Envoy fetches the JWKS again): 200" 200 "$(api_status)"
check "New key gets the highest priority" 204 "$(set_priority "$SAFE" $(($(max_priority) + 10)))"
check "New key used for signing" "$SAFE_KID" "$(signing_kid)"
check "Envoy accepts tokens signed with it: 200" 200 "$(api_status)"

summary
