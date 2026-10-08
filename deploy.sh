#!/usr/bin/env bash
# Deploys the whole platform, step by step, on the current kubectl context.
set -euo pipefail
cd "$(dirname "$0")"

CNPG_VERSION=1.30.1
KEYCLOAK_VERSION=26.8.0
ENVOY_GATEWAY_VERSION=v1.9.2

step() { printf '\n==> %s\n' "$*"; }

step "Namespaces"
kubectl apply -f 00-namespaces.yaml

step "Operators: CloudNativePG, Keycloak, Envoy Gateway"
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl apply -k "github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=${KEYCLOAK_VERSION}"
kubectl apply --server-side -f \
  "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=5m
kubectl -n keycloak rollout status deployment/keycloak-operator --timeout=5m
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=5m

step "Gateway"
scripts/gen-certs.sh
kubectl -n envoy-gateway-system create secret tls kube-localhost-tls \
  --cert=certs/tls.crt --key=certs/tls.key --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 01-gateway/
kubectl -n envoy-gateway-system wait gateway/public --for=condition=Programmed --timeout=5m

step "PostgreSQL"
kubectl apply -f 02-database/
kubectl -n keycloak wait cluster/keycloak-db --for=condition=Ready --timeout=10m

step "Keycloak"
kubectl apply -f 03-keycloak/
kubectl -n keycloak wait keycloak/keycloak --for=condition=Ready --timeout=10m

step "Demo realm"
scripts/create-secrets.sh
kubectl apply -f 04-realm/
kubectl -n keycloak wait keycloakrealmimport/demo --for=condition=Done --timeout=10m

step "Demo applications"
kubectl apply -k 05-demo/
for app in userinfo-authz intranet echo-api; do
  kubectl -n demo rollout status "deployment/$app" --timeout=5m
done

step "Done"
echo "CA certificate to trust: $(pwd)/certs/ca.crt"
echo "Run ./test.sh to check the deployment."
