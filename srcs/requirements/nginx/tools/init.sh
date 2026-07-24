#!/bin/bash
# Container entrypoint: generate a self-signed TLS cert, then run nginx as PID 1.
set -e

CERT_DIR=/etc/nginx/ssl
mkdir -p "$CERT_DIR"

# No public CA signs .42.fr, so we self-sign. -nodes = no passphrase on the key,
# so nginx can start unattended; -subj avoids the interactive prompts.
if [ ! -f "$CERT_DIR/inception.crt" ]; then
	openssl req -x509 -nodes -days 365 \
		-newkey rsa:2048 \
		-keyout "$CERT_DIR/inception.key" \
		-out "$CERT_DIR/inception.crt" \
		-subj "/CN=${DOMAIN_NAME}"
fi

# Foreground nginx: 'daemon off' keeps it PID 1 so it gets Docker's SIGTERM directly.
exec nginx -g "daemon off;"
