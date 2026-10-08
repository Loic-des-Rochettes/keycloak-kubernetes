#!/usr/bin/env bash
# Generates a local certificate authority and a wildcard certificate for
# *.kube.localhost, used by the HTTPS listener of the Gateway.
# In a real cluster, cert-manager or your PKI issues this certificate.
set -euo pipefail

DOMAIN="${DOMAIN:-kube.localhost}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
mkdir -p "$DIR"
cd "$DIR"

if [ ! -f ca.key ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
    -subj "/CN=Local demo CA (${DOMAIN})" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout ca.key -out ca.crt
fi

if [ ! -f tls.key ]; then
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=*.${DOMAIN}" \
    -keyout tls.key -out tls.csr
  openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 397 -sha256 -out tls.crt \
    -extfile <(printf "subjectAltName=DNS:*.%s,DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$DOMAIN" "$DOMAIN")
  rm -f tls.csr
fi

echo "CA certificate: $DIR/ca.crt"
