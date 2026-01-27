# Script para atualizar apenas a Container App com nova imagem
# Uso: .\azure\update-app.ps1 <resource-group> <app-name> <acr-name>

param(
    [string]$ResourceGroup = "rag-overlabs-rg",
    [string]$AppName = "rag-overlabs-app",
    [string]$AcrName = "ragoverlabsacr"
)

$ErrorActionPreference = "Stop"

Write-Host "🔄 Atualizando Container App: $AppName" -ForegroundColor Green

# Build nova imagem
Write-Host "🔨 Building new image..." -ForegroundColor Yellow
az acr build `
  --registry $AcrName `
  --image rag-api:latest `
  --file backend/Dockerfile `
  . | Out-Null

# Atualizar Container App
Write-Host "🚀 Updating container app..." -ForegroundColor Yellow
az containerapp update `
  --name $AppName `
  --resource-group $ResourceGroup `
  --image "${AcrName}.azurecr.io/rag-api:latest" | Out-Null

Write-Host ""
Write-Host "✅ Atualização concluída!" -ForegroundColor Green
$ApiUrl = az containerapp show --name $AppName --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv
Write-Host "API URL: https://$ApiUrl" -ForegroundColor Cyan
