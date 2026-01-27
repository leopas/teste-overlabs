#!/bin/bash
# Script para baixar o certificado CA do Azure MySQL
# Uso: ./azure/download-mysql-cert.sh

set -e

CERT_DIR="certs"
CERT_FILE="$CERT_DIR/DigiCertGlobalRootCA.crt.pem"

echo "📥 Downloading Azure MySQL CA certificate..."

# Criar diretório se não existir
mkdir -p $CERT_DIR

# Baixar certificado
curl -o $CERT_FILE https://cacerts.digicert.com/DigiCertGlobalRootCA.crt.pem

if [ -f "$CERT_FILE" ]; then
    echo "✅ Certificate downloaded to $CERT_FILE"
    echo "   File size: $(du -h $CERT_FILE | cut -f1)"
else
    echo "❌ Failed to download certificate"
    exit 1
fi
