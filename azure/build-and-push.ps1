# Script para build e push da imagem para ACR
# Uso: .\azure\build-and-push.ps1 <acr-name>

param(
    [Parameter(Mandatory=$true)]
    [string]$AcrName
)

$ErrorActionPreference = "Stop"

Write-Host "🔨 Building and pushing to ACR: $AcrName" -ForegroundColor Green

# Login no ACR (se necessário)
Write-Host "🔐 Logging in to ACR..." -ForegroundColor Yellow
az acr login --name $AcrName | Out-Null

# Build e push
Write-Host "🏗️ Building image..." -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
az acr build `
  --registry $AcrName `
  --image rag-api:latest `
  --image "rag-api:$timestamp" `
  --file backend/Dockerfile `
  . | Out-Null

Write-Host ""
Write-Host "✅ Build concluído!" -ForegroundColor Green
Write-Host "Imagem: ${AcrName}.azurecr.io/rag-api:latest" -ForegroundColor Cyan
Write-Host "Tag: ${AcrName}.azurecr.io/rag-api:$timestamp" -ForegroundColor Cyan
