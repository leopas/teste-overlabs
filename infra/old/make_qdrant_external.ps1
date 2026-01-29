# Script para mudar o ingress do Qdrant Container App de internal para external
# Isso permite acesso externo ao Qdrant (necessário para ingestão local)

param(
    [string]$ResourceGroup = $null,
    [string]$QdrantAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Tornar Qdrant Container App Acessível Externamente ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $QdrantAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -QdrantAppName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $QdrantAppName) {
        $QdrantAppName = $state.qdrantAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Qdrant Container App: $QdrantAppName" -ForegroundColor Yellow
Write-Host ""

# Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$QdrantAppName' não encontrado no Resource Group '$ResourceGroup'" -ForegroundColor Red
    exit 1
}

# Verificar configuração atual
Write-Host "[INFO] Verificando configuração atual do ingress..." -ForegroundColor Yellow
$currentIngress = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "properties.configuration.ingress.external" -o tsv
$currentFqdn = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv

if ($currentIngress -eq "True") {
    Write-Host "[OK] Qdrant já está configurado como external" -ForegroundColor Green
    Write-Host "[INFO] FQDN: $currentFqdn" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "URL do Qdrant: https://$currentFqdn:6333" -ForegroundColor Green
    exit 0
}

Write-Host "[INFO] Ingress atual: internal" -ForegroundColor Yellow
Write-Host "[INFO] Mudando para external..." -ForegroundColor Yellow
Write-Host ""

# Atualizar ingress para external
az containerapp ingress enable `
    --name $QdrantAppName `
    --resource-group $ResourceGroup `
    --type external `
    --target-port 6333 `
    --transport http | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Ingress atualizado para external" -ForegroundColor Green
    Write-Host ""
    
    # Aguardar alguns segundos para o FQDN ser provisionado
    Write-Host "[INFO] Aguardando FQDN ser provisionado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    # Obter novo FQDN
    $newFqdn = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv
    
    if ($newFqdn) {
        Write-Host "[OK] FQDN: $newFqdn" -ForegroundColor Green
        Write-Host ""
        Write-Host "✅ Qdrant agora é acessível externamente!" -ForegroundColor Green
        Write-Host ""
        Write-Host "URL do Qdrant: https://$newFqdn:6333" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "[AVISO] Lembre-se de proteger o acesso ao Qdrant se necessário (IP restrictions, etc.)" -ForegroundColor Yellow
    } else {
        Write-Host "[AVISO] FQDN ainda não disponível. Aguarde alguns segundos e verifique novamente." -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERRO] Falha ao atualizar ingress" -ForegroundColor Red
    exit 1
}
