# Script para baixar o certificado CA do Azure MySQL
# Uso: .\azure\download-mysql-cert.ps1

$ErrorActionPreference = "Stop"

$CertDir = "certs"
$CertFile = "$CertDir\DigiCertGlobalRootCA.crt.pem"

Write-Host "📥 Downloading Azure MySQL CA certificate..." -ForegroundColor Green

# Criar diretório se não existir
if (-not (Test-Path $CertDir)) {
    New-Item -ItemType Directory -Path $CertDir | Out-Null
}

# Baixar certificado
$CertUrl = "https://cacerts.digicert.com/DigiCertGlobalRootCA.crt.pem"
Invoke-WebRequest -Uri $CertUrl -OutFile $CertFile

if (Test-Path $CertFile) {
    $FileSize = (Get-Item $CertFile).Length / 1KB
    Write-Host "✅ Certificate downloaded to $CertFile" -ForegroundColor Green
    Write-Host "   File size: $([math]::Round($FileSize, 2)) KB" -ForegroundColor Cyan
} else {
    Write-Host "❌ Failed to download certificate" -ForegroundColor Red
    exit 1
}
