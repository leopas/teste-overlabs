# Script completo para diagnosticar resolução do Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Diagnóstico Completo: Key Vault Resolution ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $ApiAppName) {
        $ApiAppName = $state.apiAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar secret no Key Vault
Write-Host "[1/5] Verificando secret no Key Vault..." -ForegroundColor Yellow
$kvName = $state.keyVaultName
$secretName = "openai-api-key"

$secretExists = az keyvault secret show --vault-name $kvName --name $secretName --query "name" -o tsv 2>&1
if ($secretExists) {
    Write-Host "[OK] Secret '$secretName' existe no Key Vault '$kvName'" -ForegroundColor Green
    
    # Verificar valor (sem mostrar completo)
    $secretValue = az keyvault secret show --vault-name $kvName --name $secretName --query "value" -o tsv 2>&1
    if ($secretValue -and $secretValue.StartsWith("sk-")) {
        Write-Host "[OK] Secret tem formato correto (começa com 'sk-')" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Secret não tem formato correto!" -ForegroundColor Red
    }
} else {
    Write-Host "[ERRO] Secret '$secretName' não encontrado no Key Vault!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 2. Verificar Managed Identity
Write-Host "[2/5] Verificando Managed Identity..." -ForegroundColor Yellow
$mi = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json 2>&1 | ConvertFrom-Json

if ($mi.type -match "SystemAssigned") {
    Write-Host "[OK] Managed Identity habilitada: $($mi.type)" -ForegroundColor Green
    $principalId = $mi.principalId
    Write-Host "[INFO] Principal ID: $principalId" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity não está habilitada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Verificar permissões RBAC
Write-Host "[3/5] Verificando permissões RBAC..." -ForegroundColor Yellow
$kvScope = "/subscriptions/06cd0a82-44bf-42fe-ab19-2851e9301697/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$kvName"
$rbac = az role assignment list --assignee $principalId --scope $kvScope --query "[?roleDefinitionName=='Key Vault Secrets User']" -o json 2>&1 | ConvertFrom-Json

if ($rbac.Count -gt 0) {
    Write-Host "[OK] Permissão 'Key Vault Secrets User' configurada" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Permissão 'Key Vault Secrets User' não encontrada!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\fix_keyvault_rbac.ps1" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 4. Verificar referência no Container App
Write-Host "[4/5] Verificando referência no Container App..." -ForegroundColor Yellow
$envVar = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env[?name=='OPENAI_API_KEY'].value" -o tsv 2>&1

if ($envVar -match "KeyVault") {
    Write-Host "[OK] Referência Key Vault configurada" -ForegroundColor Green
    Write-Host "[INFO] Referência: $envVar" -ForegroundColor Gray
    
    # Verificar se a referência está correta
    if ($envVar -match "openai-api-key") {
        Write-Host "[OK] Nome do secret está correto na referência" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Nome do secret pode estar incorreto na referência" -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERRO] Referência Key Vault não encontrada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 5. Verificar se está sendo resolvida no container (via logs)
Write-Host "[5/5] Verificando logs do container..." -ForegroundColor Yellow
Write-Host "[INFO] Procurando erros relacionados a Key Vault..." -ForegroundColor Gray

$logs = az containerapp logs show --name $ApiAppName --resource-group $ResourceGroup --tail 100 --type console 2>&1
$kvErrors = $logs | Select-String -Pattern "KeyVault|keyvault|401|Unauthorized" -CaseSensitive:$false

if ($kvErrors) {
    Write-Host "[AVISO] Encontrados erros relacionados a Key Vault nos logs:" -ForegroundColor Yellow
    $kvErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "[INFO] Nenhum erro explícito de Key Vault nos logs recentes" -ForegroundColor Gray
}
Write-Host ""

Write-Host "=== Resumo do Diagnóstico ===" -ForegroundColor Cyan
Write-Host "[OK] Secret existe no Key Vault" -ForegroundColor Green
Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
Write-Host "[OK] Permissões RBAC configuradas" -ForegroundColor Green
Write-Host "[OK] Referência configurada no Container App" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Se a ingestão ainda falhar com 401, possíveis causas:" -ForegroundColor Yellow
Write-Host "  1. Container Apps pode precisar de mais tempo para resolver a referência" -ForegroundColor Gray
Write-Host "  2. A referência pode precisar incluir a versão do secret" -ForegroundColor Gray
Write-Host "  3. Pode haver um problema de rede/firewall entre Container App e Key Vault" -ForegroundColor Gray
Write-Host ""
Write-Host "[INFO] Tente:" -ForegroundColor Yellow
Write-Host "  1. Aguardar mais alguns minutos e tentar novamente" -ForegroundColor Gray
Write-Host "  2. Reiniciar o Container App: az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision <latest>" -ForegroundColor Gray
Write-Host "  3. Verificar se o secret não está expirado no Key Vault" -ForegroundColor Gray
Write-Host ""
