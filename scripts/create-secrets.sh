#!/usr/bin/env bash
# Creates the Secrets of the demo with random values. Existing Secrets are kept,
# so the script can run several times.
#   keycloak/demo-realm-secrets       placeholders of the realm import
#   demo/intranet-oidc-client         client secret read by the Envoy Gateway OIDC filter
set -euo pipefail

rand() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

if ! kubectl -n keycloak get secret demo-realm-secrets >/dev/null 2>&1; then
  kubectl -n keycloak create secret generic demo-realm-secrets \
    --from-literal=alice-password="$(rand)" \
    --from-literal=bob-password="$(rand)" \
    --from-literal=intranet-client-secret="$(rand)" \
    --from-literal=reporting-job-secret="$(rand)" \
    --from-literal=inventory-sync-secret="$(rand)"
fi

# Same value as the intranet client secret of the realm.
INTRANET_CLIENT_SECRET="$(kubectl -n keycloak get secret demo-realm-secrets \
  -o jsonpath='{.data.intranet-client-secret}' | base64 -d)"
kubectl -n demo create secret generic intranet-oidc-client \
  --from-literal=client-secret="$INTRANET_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
