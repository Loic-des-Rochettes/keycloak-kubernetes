#!/usr/bin/env bash
# End-to-end checks of the deployment: from outside the cluster through the
# Gateway (curl), and from inside the cluster (NetworkPolicies).
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib.sh

PYTHON_IMAGE=python:3.14.8-alpine3.24
CACHE_TTL_SECONDS=10

ALICE_PASSWORD="$(secret keycloak demo-realm-secrets alice-password)"
BOB_PASSWORD="$(secret keycloak demo-realm-secrets bob-password)"
REPORTING_JOB_SECRET="$(secret keycloak demo-realm-secrets reporting-job-secret)"
INVENTORY_SYNC_SECRET="$(secret keycloak demo-realm-secrets inventory-sync-secret)"

section "Platform"
check "CloudNativePG: 3 ready instances" 3 \
  "$(kubectl -n keycloak get cluster keycloak-db -o jsonpath='{.status.readyInstances}')"
PRIMARY="$(kubectl -n keycloak get cluster keycloak-db -o jsonpath='{.status.currentPrimary}')"
check "PostgreSQL: quorum synchronous replication" 'ANY 1 (' \
  "$(kubectl -n keycloak exec "$PRIMARY" -c postgres -- psql -tAc 'show synchronous_standby_names' | cut -c1-7)"
check "Keycloak CR Ready" True \
  "$(kubectl -n keycloak get keycloak keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
check "Keycloak: 2 ready pods" 2 \
  "$(kubectl -n keycloak get statefulset keycloak -o jsonpath='{.status.readyReplicas}')"
VIEW="$(kubectl -n keycloak logs keycloak-0 | grep 'ISPN000094' | tail -1)"
case "$VIEW" in
  *"(2)"*) pass "Keycloak: 2-member Infinispan cluster" ;;
  *) fail "Keycloak: 2-member Infinispan cluster (last view: ${VIEW:-none})" ;;
esac
check "Gateway programmed" True \
  "$(kubectl -n envoy-gateway-system get gateway public -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
check "Envoy: 2 proxy replicas" 2 \
  "$(kubectl -n envoy-gateway-system get deployment -l gateway.envoyproxy.io/owning-gateway-name=public -o jsonpath='{.items[0].status.readyReplicas}')"

section "Keycloak exposure"
check "OIDC discovery: public issuer" "$KC/realms/demo" \
  "$(c "$KC/realms/demo/.well-known/openid-configuration" | jq -r .issuer)"
check "HTTP redirects to HTTPS" 301 "$(curl -s -o /dev/null -w '%{http_code}' http://keycloak.kube.localhost/realms/demo)"
check "Public hostname: /admin not exposed" 404 "$(http_code "$KC/admin/master/console/")"
check "Public hostname: master realm not exposed" 404 \
  "$(http_code "$KC/realms/master/.well-known/openid-configuration")"
check "Public hostname: /metrics not exposed" 404 "$(http_code "$KC/metrics")"
check "Admin hostname: console available" 200 "$(http_code "$KC_ADMIN/admin/master/console/")"

section "API (bearer token)"
READ_TOKEN="$(client_token reporting-job "$REPORTING_JOB_SECRET")"
WRITE_TOKEN="$(client_token inventory-sync "$INVENTORY_SYNC_SECRET")"
check "No token: 401" 401 "$(http_code "$API/items")"
check "Invalid token: 401" 401 "$(http_code -H 'Authorization: Bearer not-a-jwt' "$API/items")"
FORGED="$(printf '%s' "$READ_TOKEN" | cut -d. -f1,2).c2lnbmF0dXJl"
check "Forged signature: 401" 401 "$(http_code -H "Authorization: Bearer $FORGED" "$API/items")"
check "reporting-job GET (role read): 200" 200 \
  "$(http_code -H "Authorization: Bearer $READ_TOKEN" "$API/items")"
check "reporting-job POST (no role write): 403" 403 \
  "$(http_code -H "Authorization: Bearer $READ_TOKEN" -H 'Content-Type: application/json' -d '{"name":"mouse"}' "$API/items")"
check "inventory-sync POST (role write): 201" 201 \
  "$(http_code -H "Authorization: Bearer $WRITE_TOKEN" -H 'Content-Type: application/json' -d '{"name":"mouse"}' "$API/items")"
check "Header X-Client-Id from the azp claim, client value ignored" reporting-job \
  "$(c -H "Authorization: Bearer $READ_TOKEN" -H 'X-Client-Id: admin-console' "$API/items" | jq -r .caller.client_id)"

section "Intranet (OIDC login, legacy application)"
check_prefix "Anonymous request redirected to Keycloak" "$KC/realms/demo/protocol/openid-connect/auth?" \
  "$(c -o /dev/null -w '%{redirect_url}' "$INTRANET/whoami")"
check "alice signs in: 200" 200 "$(browser_login alice "$ALICE_PASSWORD" "$INTRANET/whoami")"
WHOAMI="$TMP/alice.body"
check "X-Remote-User from the token" alice "$(jq -r '.identity["X-Remote-User"]' "$WHOAMI")"
check "X-Remote-Name from the token" "Alice Martin" "$(jq -r '.identity["X-Remote-Name"]' "$WHOAMI")"
check "X-Remote-Email from the token" alice@example.com "$(jq -r '.identity["X-Remote-Email"]' "$WHOAMI")"
check "X-Remote-Groups from UserInfo" staff "$(jq -r '.identity["X-Remote-Groups"]' "$WHOAMI")"
check "X-Remote-Employee-Id from UserInfo" E-1001 "$(jq -r '.identity["X-Remote-Employee-Id"]' "$WHOAMI")"
check "X-Remote-Department from UserInfo" Finance "$(jq -r '.identity["X-Remote-Department"]' "$WHOAMI")"
check "The application does not receive the access token" false "$(jq -r .authorization_header "$WHOAMI")"
SPOOF="$(c -b "$TMP/alice.jar" -H 'X-Remote-User: admin' -H 'X-Remote-Employee-Id: E-0000' \
  -H 'X-Client-Id: forged' -H 'X-Forwarded-For: 203.0.113.66' "$INTRANET/whoami")"
check "Spoofed X-Remote-User replaced" alice "$(printf '%s' "$SPOOF" | jq -r '.identity["X-Remote-User"]')"
check "Spoofed X-Remote-Employee-Id replaced" E-1001 \
  "$(printf '%s' "$SPOOF" | jq -r '.identity["X-Remote-Employee-Id"]')"
check "Identity header not set by this route (X-Client-Id) removed" false \
  "$(printf '%s' "$SPOOF" | jq '.headers | index("X-Client-Id") != null')"
case "$(printf '%s' "$SPOOF" | jq -r .x_forwarded_for)" in
  *203.0.113.66*) fail "Spoofed X-Forwarded-For removed" ;;
  *) pass "Spoofed X-Forwarded-For removed (seen: $(printf '%s' "$SPOOF" | jq -r .x_forwarded_for))" ;;
esac
check "bob (contractors, no intranet role) signs in: 403" 403 \
  "$(browser_login bob "$BOB_PASSWORD" "$INTRANET/whoami")"

check_prefix "Logout redirects to the Keycloak end session endpoint" \
  "$KC/realms/demo/protocol/openid-connect/logout" \
  "$(c -o /dev/null -w '%{redirect_url}' -c "$TMP/alice.jar" -b "$TMP/alice.jar" "$INTRANET/logout")"
check_prefix "After logout, the intranet asks to sign in again" "$KC/realms/demo/protocol/openid-connect/auth?" \
  "$(c -o /dev/null -w '%{redirect_url}' -b "$TMP/alice.jar" "$INTRANET/whoami")"

section "Session revocation (UserInfo check)"
browser_login alice "$ALICE_PASSWORD" "$INTRANET/whoami" >/dev/null
check "alice signed in again" 200 "$(http_code -b "$TMP/alice.jar" "$INTRANET/whoami")"
ADMIN_TOKEN="$(admin_token)"
ALICE_ID="$(c -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KC_ADMIN/admin/realms/demo/users?username=alice&exact=true" | jq -r '.[0].id')"
check "Administrator ends alice's sessions" 204 \
  "$(http_code -X POST -H "Authorization: Bearer $ADMIN_TOKEN" "$KC_ADMIN/admin/realms/demo/users/$ALICE_ID/logout")"
sleep $((CACHE_TTL_SECONDS + 1))
check "Access refused although the access token has not expired: 401" 401 \
  "$(c -o "$TMP/revoked.body" -w '%{http_code}' -b "$TMP/alice.jar" "$INTRANET/whoami")"
check "Refused by the UserInfo check (ext_authz)" "Session ended." "$(cut -c1-14 "$TMP/revoked.body")"

section "NetworkPolicies (from inside the cluster)"
probe() { # namespace -> prints "host open|blocked" for each target
  kubectl -n "$1" run "np-probe-$RANDOM" --rm -i --quiet --restart=Never --image="$PYTHON_IMAGE" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"'"$PYTHON_IMAGE"'","command":["python","-c","import socket\nfor t in [(\"intranet.demo.svc.cluster.local\",8080),(\"keycloak-service.keycloak.svc.cluster.local\",8080),(\"keycloak-db-rw.keycloak.svc.cluster.local\",5432)]:\n  s=socket.socket();s.settimeout(3)\n  try:\n    s.connect(t);print(\"%s:%s open\"%t)\n  except Exception:\n    print(\"%s:%s blocked\"%t)"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    2>/dev/null
}
FROM_DEFAULT="$(probe default)"
FROM_ENVOY="$(probe envoy-gateway-system)"
state() { printf '%s\n' "$1" | grep "^$2:" | awk '{print $2}'; }
check "default -> intranet:8080 blocked" blocked "$(state "$FROM_DEFAULT" intranet.demo.svc.cluster.local)"
check "default -> keycloak:8080 blocked" blocked "$(state "$FROM_DEFAULT" keycloak-service.keycloak.svc.cluster.local)"
check "default -> postgresql:5432 blocked" blocked "$(state "$FROM_DEFAULT" keycloak-db-rw.keycloak.svc.cluster.local)"
check "envoy-gateway-system -> intranet:8080 open" open "$(state "$FROM_ENVOY" intranet.demo.svc.cluster.local)"
check "envoy-gateway-system -> keycloak:8080 open" open "$(state "$FROM_ENVOY" keycloak-service.keycloak.svc.cluster.local)"
check "envoy-gateway-system -> postgresql:5432 blocked" blocked "$(state "$FROM_ENVOY" keycloak-db-rw.keycloak.svc.cluster.local)"

summary
