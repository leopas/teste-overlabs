# Script para corrigir o caminho do certificado MySQL no Container App
# O certificado deve estar em /app/certs/DigiCertGlobalRootCA.crt.pem no container

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiApp = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Correção de Caminho do Certificado MySQL ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar valor atual
Write-Host "[1/3] Verificando valor atual de MYSQL_SSL_CA..." -ForegroundColor Yellow
$envVars = az containerapp show `
    --name $ApiApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env" `
    -o json | ConvertFrom-Json

$currentValue = $null
foreach ($env in $envVars) {
    if ($env.name -eq "MYSQL_SSL_CA") {
        $currentValue = $env.value
        break
    }
}

if (-not $currentValue) {
    Write-Host "  [ERRO] MYSQL_SSL_CA não encontrada" -ForegroundColor Red
    exit 1
}

Write-Host "  Valor atual: $currentValue" -ForegroundColor Cyan

# 2. Verificar se o certificado existe no container (opcional - pode falhar se container não estiver rodando)
Write-Host ""
Write-Host "[2/3] Verificando se certificado existe no container..." -ForegroundColor Yellow
Write-Host "  (Verificando se o Dockerfile copia certs/ para /app/certs/)" -ForegroundColor Gray

# Verificar Dockerfile
$dockerfilePath = "backend\Dockerfile"
if (Test-Path $dockerfilePath) {
    $dockerfileContent = Get-Content $dockerfilePath -Raw
    if ($dockerfileContent -match "COPY certs") {
        Write-Host "  [OK] Dockerfile contém 'COPY certs'" -ForegroundColor Green
        $certExists = $true
    } else {
        Write-Host "  [AVISO] Dockerfile não contém 'COPY certs'" -ForegroundColor Yellow
        $certExists = $false
    }
} else {
    Write-Host "  [AVISO] Dockerfile não encontrado" -ForegroundColor Yellow
    $certExists = $null
}

# 3. Corrigir se necessário
Write-Host ""
Write-Host "[3/3] Corrigindo variável MYSQL_SSL_CA..." -ForegroundColor Yellow

$correctPath = "/app/certs/DigiCertGlobalRootCA.crt.pem"

if ($currentValue -ne $correctPath) {
    Write-Host "  Atualizando de '$currentValue' para '$correctPath'..." -ForegroundColor Cyan
    
    az containerapp update `
        --name $ApiApp `
        --resource-group $ResourceGroup `
        --set-env-vars "MYSQL_SSL_CA=$correctPath" | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Variável atualizada com sucesso" -ForegroundColor Green
    } else {
        Write-Host "  [ERRO] Falha ao atualizar variável" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [OK] Variável já está correta: $correctPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "  Certificado no container: $(if ($certExists) { '[OK]' } else { '[ERRO]' })" -ForegroundColor $(if ($certExists) { 'Green' } else { 'Red' })
Write-Host "  MYSQL_SSL_CA: $correctPath" -ForegroundColor $(if ($currentValue -eq $correctPath) { 'Green' } else { 'Yellow' })
Write-Host ""
Write-Host "Próximos passos:" -ForegroundColor Yellow
if (-not $certExists) {
    Write-Host "  1. Verificar se o certificado está na pasta certs/ localmente" -ForegroundColor Cyan
    Write-Host "  2. Verificar se o Dockerfile copia certs/ para /app/certs/" -ForegroundColor Cyan
    Write-Host "  3. Rebuild da imagem Docker" -ForegroundColor Cyan
}
