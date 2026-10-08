#!/usr/bin/env bash
# Resilience checks, on a single node: failover of the PostgreSQL primary, then
# restart of every Keycloak pod, while a user keeps signing in to the intranet.
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib.sh

CACHE_TTL_SECONDS=10
ALICE_PASSWORD="$(secret keycloak demo-realm-secrets alice-password)"

# Signs alice in every 2 seconds until the file $TMP/stop exists, and logs the
# time and HTTP status of each attempt.
login_loop() { # log file
  while [ ! -f "$TMP/stop" ]; do
    printf '%s %s\n' "$(date +%T)" "$(browser_login alice "$ALICE_PASSWORD" "$INTRANET/whoami" loop 2>/dev/null)" >>"$1"
    sleep 2
  done
}
report() { # log file
  local total failed
  total="$(wc -l <"$1" | tr -d ' ')"
  failed="$(grep -vc ' 200$' "$1")"
  printf '  %s sign-ins, %s failed' "$total" "$failed"
  [ "$failed" -gt 0 ] && printf ' (%s to %s)' "$(grep -v ' 200$' "$1" | head -1 | cut -d' ' -f1)" \
    "$(grep -v ' 200$' "$1" | tail -1 | cut -d' ' -f1)"
  printf '\n'
}

section "PostgreSQL: crash of the primary"
OLD_PRIMARY="$(kubectl -n keycloak get cluster keycloak-db -o jsonpath='{.status.currentPrimary}')"
rm -f "$TMP/stop"
login_loop "$TMP/pg.log" &
sleep 6
START=$SECONDS
# No grace period: simulates a crash. A plain "kubectl delete pod" triggers a
# smart shutdown that keeps serving open connections for up to 180 seconds.
kubectl -n keycloak delete pod "$OLD_PRIMARY" --grace-period=0 --force >/dev/null 2>&1
NEW_PRIMARY=""
while [ $((SECONDS - START)) -lt 180 ]; do
  NEW_PRIMARY="$(kubectl -n keycloak get cluster keycloak-db -o jsonpath='{.status.currentPrimary}')"
  [ -n "$NEW_PRIMARY" ] && [ "$NEW_PRIMARY" != "$OLD_PRIMARY" ] && break
  sleep 1
done
check "A standby is promoted ($OLD_PRIMARY -> $NEW_PRIMARY, $((SECONDS - START))s)" true \
  "$([ "$NEW_PRIMARY" != "$OLD_PRIMARY" ] && echo true)"
kubectl -n keycloak wait cluster/keycloak-db --for=condition=Ready --timeout=5m >/dev/null
check "Cluster back to 3 ready instances" 3 \
  "$(kubectl -n keycloak get cluster keycloak-db -o jsonpath='{.status.readyInstances}')"
sleep 20
touch "$TMP/stop"
wait
report "$TMP/pg.log"
check "Sign-ins succeed after the failover" "200 200 200" "$(tail -3 "$TMP/pg.log" | cut -d' ' -f2 | xargs)"

section "Keycloak: restart of every pod, one at a time"
check "alice signs in before the restarts" 200 "$(browser_login alice "$ALICE_PASSWORD" "$INTRANET/whoami" session)"
rm -f "$TMP/stop"
login_loop "$TMP/kc.log" &
for pod in keycloak-1 keycloak-0; do
  kubectl -n keycloak delete pod "$pod" >/dev/null
  sleep 5
  kubectl -n keycloak wait pod "$pod" --for=condition=Ready --timeout=5m >/dev/null
done
sleep 10
touch "$TMP/stop"
wait
report "$TMP/kc.log"
check "Sign-ins succeed after the restarts" "200 200 200" "$(tail -3 "$TMP/kc.log" | cut -d' ' -f2 | xargs)"
sleep "$CACHE_TTL_SECONDS"
check "Session opened before the restarts still valid (UserInfo)" 200 \
  "$(http_code -b "$TMP/session.jar" "$INTRANET/whoami")"

summary
