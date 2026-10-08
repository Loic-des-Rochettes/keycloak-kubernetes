#!/usr/bin/env bash
# Removes everything deploy.sh created. Custom resources go first, while their
# operators are still running to process the deletion.
set -uo pipefail
cd "$(dirname "$0")"

CNPG_VERSION=1.30.1
KEYCLOAK_VERSION=26.8.0
ENVOY_GATEWAY_VERSION=v1.9.2

kubectl delete -k 05-demo/ --ignore-not-found --wait
kubectl delete -f 04-realm/ -f 03-keycloak/ --ignore-not-found --wait --cascade=foreground
# Foreground: the PostgreSQL pods stop while their namespace still exists. Once
# their ServiceAccount is gone, an instance can no longer archive its WAL and
# waits up to stopDelay (30 minutes) before stopping.
kubectl delete -f 02-database/ --ignore-not-found --wait --cascade=foreground
kubectl delete -f 01-gateway/ --ignore-not-found --wait
kubectl -n envoy-gateway-system delete secret kube-localhost-tls --ignore-not-found

kubectl delete -k "github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=${KEYCLOAK_VERSION}" --ignore-not-found
kubectl delete -f 00-namespaces.yaml --ignore-not-found --wait
kubectl delete -f "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml" \
  --ignore-not-found
kubectl delete -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml" \
  --ignore-not-found
