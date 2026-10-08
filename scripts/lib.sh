# Shared by test.sh and test-failover.sh.

CA=certs/ca.crt
KC=https://keycloak.kube.localhost
KC_ADMIN=https://keycloak-admin.kube.localhost
INTRANET=https://intranet.kube.localhost
API=https://api.kube.localhost

TMP="$(mktemp -d)"
trap 'jobs -p | xargs kill 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
section() { printf '\n%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
# check <description> <expected> <actual>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
# check_prefix <description> <expected prefix> <actual>
check_prefix() { case "$3" in "$2"*) pass "$1" ;; *) fail "$1 (expected '$2...', got '$3')" ;; esac; }
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

c() { curl -sS --cacert "$CA" "$@"; }
http_code() { c -o /dev/null -w '%{http_code}' "$@"; }
secret() { kubectl -n "$1" get secret "$2" -o go-template="{{index .data \"$3\" | base64decode}}"; }

client_token() { # client_id secret
  c -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$2" \
    "$KC/realms/demo/protocol/openid-connect/token" | jq -r .access_token
}

admin_token() {
  c -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=$(secret keycloak keycloak-initial-admin username)" \
    --data-urlencode "password=$(secret keycloak keycloak-initial-admin password)" \
    "$KC_ADMIN/realms/master/protocol/openid-connect/token" | jq -r .access_token
}

# Authorization code flow driven with curl: follows the redirects to the login
# form of Keycloak, posts the credentials, and lets curl follow the redirects
# back to the application. Prints the HTTP status of the last response; the
# body is in $TMP/<jar>.body and the cookies in $TMP/<jar>.jar.
browser_login() { # user password url [jar name]
  local name="${4:-$1}" page action
  local jar="$TMP/$name.jar"
  rm -f "$jar"
  page="$(c -L -c "$jar" -b "$jar" "$3")"
  action="$(printf '%s' "$page" | grep -o 'action="[^"]*login-actions/authenticate[^"]*"' | head -1 |
    sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')"
  [ -n "$action" ] || { echo 000; return; }
  c -L -c "$jar" -b "$jar" -o "$TMP/$name.body" -w '%{http_code}' \
    --data-urlencode "username=$1" --data-urlencode "password=$2" "$action"
}
