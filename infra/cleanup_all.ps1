# Script para deletar completamente o ambiente Azure da overlabs
# Uso: .\infra\cleanup_all.ps1 [-ResourceGroup "rg-overlabs-prod"] [-Force]

param(
    [string]$ResourceGroup = $null,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Limpeza Completa do Ambiente Azure ===" -ForegroundColor Red
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup) {
    $stateFile = ".azure/deploy_state.json"
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json
        $ResourceGroup = $state.resourceGroup
        Write-Host "[INFO] Resource Group carregado do deploy_state.json: $ResourceGroup" -ForegroundColor Yellow
    } else {
        Write-Host "[ERRO] Resource Group não fornecido e deploy_state.json não encontrado" -ForegroundColor Red
        Write-Host "[INFO] Uso: .\infra\cleanup_all.ps1 -ResourceGroup 'rg-overlabs-prod'" -ForegroundColor Yellow
        exit 1
    }
}

if (-not $Force) {
    Write-Host "[AVISO] Este script vai DELETAR TODOS os recursos no Resource Group: $ResourceGroup" -ForegroundColor Yellow
    Write-Host "[AVISO] Isso inclui:" -ForegroundColor Yellow
    Write-Host "  - Container Apps (API, Qdrant, Redis)" -ForegroundColor Gray
    Write-Host "  - Container Apps Environment" -ForegroundColor Gray
    Write-Host "  - Key Vault" -ForegroundColor Gray
    Write-Host "  - Storage Account e File Shares" -ForegroundColor Gray
    Write-Host "  - Resource Group (opcional)" -ForegroundColor Gray
    Write-Host ""
    $confirm = Read-Host "Digite 'SIM' para confirmar a exclusão"
    if ($confirm -ne "SIM") {
        Write-Host "[INFO] Operação cancelada" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "[INFO] Iniciando limpeza..." -ForegroundColor Cyan
Write-Host ""

# Listar recursos antes de deletar
Write-Host "[INFO] Listando recursos no Resource Group..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$resources = az resource list --resource-group $ResourceGroup --query "[].{name:name, type:type}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($resources) {
    Write-Host "[INFO] Recursos encontrados:" -ForegroundColor Yellow
    foreach ($resource in $resources) {
        Write-Host "  - $($resource.name) ($($resource.type))" -ForegroundColor Gray
    }
    Write-Host ""
}

# 1. Deletar Container Apps (precisa deletar antes do Environment)
Write-Host "[INFO] Deletando Container Apps..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# API
$apiApp = az containerapp list --resource-group $ResourceGroup --query "[?contains(name, 'app-overlabs') && !contains(name, 'qdrant') && !contains(name, 'redis')].name" -o tsv 2>$null
if ($apiApp) {
    Write-Host "  Deletando API Container App: $apiApp" -ForegroundColor Gray
    az containerapp delete --name $apiApp --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] API deletada" -ForegroundColor Green
    }
}

# Qdrant
$qdrantApp = az containerapp list --resource-group $ResourceGroup --query "[?contains(name, 'qdrant')].name" -o tsv 2>$null
if ($qdrantApp) {
    Write-Host "  Deletando Qdrant Container App: $qdrantApp" -ForegroundColor Gray
    az containerapp delete --name $qdrantApp --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Qdrant deletado" -ForegroundColor Green
    }
}

# Redis
$redisApp = az containerapp list --resource-group $ResourceGroup --query "[?contains(name, 'redis')].name" -o tsv 2>$null
if ($redisApp) {
    Write-Host "  Deletando Redis Container App: $redisApp" -ForegroundColor Gray
    az containerapp delete --name $redisApp --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Redis deletado" -ForegroundColor Green
    }
}

Write-Host "[INFO] Aguardando Container Apps serem deletados..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# 2. Deletar Container Apps Environment
Write-Host "[INFO] Deletando Container Apps Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$envs = az containerapp env list --resource-group $ResourceGroup --query "[].name" -o tsv 2>$null
foreach ($env in $envs) {
    Write-Host "  Deletando Environment: $env" -ForegroundColor Gray
    az containerapp env delete --name $env --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Environment deletado" -ForegroundColor Green
    }
}
$ErrorActionPreference = "Stop"

# 3. Deletar Key Vault
Write-Host "[INFO] Deletando Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$keyVaults = az keyvault list --resource-group $ResourceGroup --query "[?contains(name, 'overlabs')].name" -o tsv 2>$null
foreach ($kv in $keyVaults) {
    Write-Host "  Deletando Key Vault: $kv" -ForegroundColor Gray
    az keyvault delete --name $kv --resource-group $ResourceGroup 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Key Vault deletado" -ForegroundColor Green
    }
}
$ErrorActionPreference = "Stop"

# 4. Deletar Storage Account (e File Shares)
Write-Host "[INFO] Deletando Storage Account..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$storageAccounts = az storage account list --resource-group $ResourceGroup --query "[?contains(name, 'overlabs')].name" -o tsv 2>$null
foreach ($sa in $storageAccounts) {
    Write-Host "  Deletando Storage Account: $sa" -ForegroundColor Gray
    az storage account delete --name $sa --resource-group $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Storage Account deletado" -ForegroundColor Green
    }
}
$ErrorActionPreference = "Stop"

# 5. Deletar Resource Group (opcional - descomente se quiser deletar tudo)
Write-Host ""
Write-Host "[INFO] Recursos deletados com sucesso!" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] O Resource Group '$ResourceGroup' ainda existe." -ForegroundColor Yellow
Write-Host "[INFO] Para deletar o Resource Group completo (e todos os recursos restantes), execute:" -ForegroundColor Yellow
Write-Host "  az group delete --name $ResourceGroup --yes --no-wait" -ForegroundColor Gray
Write-Host ""

# Limpar deploy_state.json
$stateFile = ".azure/deploy_state.json"
if (Test-Path $stateFile) {
    Write-Host "[INFO] Removendo deploy_state.json..." -ForegroundColor Yellow
    Remove-Item $stateFile -Force
    Write-Host "[OK] deploy_state.json removido" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Limpeza Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
Write-Host "  1. Execute o bootstrap novamente: .\infra\bootstrap_container_apps.ps1 -EnvFile '.env' -Stage 'prod'" -ForegroundColor Gray
Write-Host "  2. Valide a configuração: .\infra\validate_bootstrap.ps1" -ForegroundColor Gray
Write-Host ""
