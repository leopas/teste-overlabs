# Resumo da verificação do certificado MySQL

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiApp = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Resumo da Verificação do Certificado MySQL ===" -ForegroundColor Cyan
Write-Host ""

# 1. Certificado local
Write-Host "[1] Certificado Local:" -ForegroundColor Yellow
if (Test-Path "certs\DigiCertGlobalRootCA.crt.pem") {
    $localCert = Get-Content "certs\DigiCertGlobalRootCA.crt.pem" -Raw
    Write-Host "  [OK] Existe: certs\DigiCertGlobalRootCA.crt.pem" -ForegroundColor Green
    Write-Host "       Tamanho: $($localCert.Length) caracteres" -ForegroundColor Cyan
} else {
    Write-Host "  [ERRO] NÃO existe" -ForegroundColor Red
    Write-Host "         Execute: .\azure\download-mysql-cert.ps1" -ForegroundColor Yellow
}

Write-Host ""

# 2. Dockerfile
Write-Host "[2] Dockerfile:" -ForegroundColor Yellow
$dockerfile = Get-Content "backend\Dockerfile" -Raw
if ($dockerfile -match "COPY certs") {
    Write-Host "  [OK] Contém 'COPY certs /app/certs'" -ForegroundColor Green
} else {
    Write-Host "  [ERRO] NÃO contém 'COPY certs'" -ForegroundColor Red
}

Write-Host ""

# 3. Variável MYSQL_SSL_CA no Container App
Write-Host "[3] Variável MYSQL_SSL_CA no Container App:" -ForegroundColor Yellow
$envVars = az containerapp show `
    --name $ApiApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env" `
    -o json | ConvertFrom-Json

$mysqlSslCa = $null
foreach ($env in $envVars) {
    if ($env.name -eq "MYSQL_SSL_CA") {
        $mysqlSslCa = $env.value
        break
    }
}

if ($mysqlSslCa) {
    Write-Host "  [OK] Encontrada: $mysqlSslCa" -ForegroundColor Green
    
    if ($mysqlSslCa -eq "/app/certs/DigiCertGlobalRootCA.crt.pem") {
        Write-Host "       [OK] Caminho correto (absoluto)" -ForegroundColor Green
    } elseif ($mysqlSslCa -match "^\./|^[^/]") {
        Write-Host "       [ERRO] Caminho relativo (deve ser absoluto)" -ForegroundColor Red
        Write-Host "              Execute: .\infra\fix_mysql_cert_path.ps1" -ForegroundColor Yellow
    } else {
        Write-Host "       [AVISO] Valor pode ser conteúdo do certificado ou outro caminho" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ERRO] NÃO encontrada" -ForegroundColor Red
    Write-Host "         Configure no bootstrap ou manualmente" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Conclusão ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Status:" -ForegroundColor Yellow

$allOk = $true
if (-not (Test-Path "certs\DigiCertGlobalRootCA.crt.pem")) {
    Write-Host "  [ ] Certificado local" -ForegroundColor Red
    $allOk = $false
} else {
    Write-Host "  [OK] Certificado local" -ForegroundColor Green
}

if (-not ($dockerfile -match "COPY certs")) {
    Write-Host "  [ ] Dockerfile copia certs" -ForegroundColor Red
    $allOk = $false
} else {
    Write-Host "  [OK] Dockerfile copia certs" -ForegroundColor Green
}

if (-not $mysqlSslCa -or $mysqlSslCa -ne "/app/certs/DigiCertGlobalRootCA.crt.pem") {
    Write-Host "  [ ] MYSQL_SSL_CA configurada corretamente" -ForegroundColor Red
    $allOk = $false
} else {
    Write-Host "  [OK] MYSQL_SSL_CA configurada corretamente" -ForegroundColor Green
}

Write-Host ""
if ($allOk) {
    Write-Host "✅ Tudo configurado corretamente!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Nota: Se ainda houver erro 'Invalid CA Certificate', pode ser necessário:" -ForegroundColor Yellow
    Write-Host "  1. Rebuild da imagem Docker (para incluir o certificado)" -ForegroundColor Cyan
    Write-Host "  2. Verificar se o certificado está sendo lido corretamente pelo mysql.connector" -ForegroundColor Cyan
} else {
    Write-Host "⚠️  Ainda há problemas a corrigir" -ForegroundColor Yellow
}
