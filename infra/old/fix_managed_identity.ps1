# Script para habilitar Managed Identity e configurar permissões no Key Vault

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVault = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Habilitar Managed Identity e Configurar Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVault) {
    $stateFile = ".azure/deploy_state.json"
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
    if (-not $KeyVault) {
        $KeyVault = $state.keyVaultName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVault" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar se Managed Identity já está habilitada
Write-Host "=== 1. Verificando Managed Identity ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$currentMi = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($currentMi) {
    Write-Host "[OK] Managed Identity já está habilitada" -ForegroundColor Green
    Write-Host "  Principal ID: $currentMi" -ForegroundColor Gray
    $principalId = $currentMi
} else {
    Write-Host "[INFO] Habilitando Managed Identity..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $miOutput = az containerapp identity assign `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --system-assigned 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $principalId = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv
        Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
        Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
    } else {
        Write-Host "[ERRO] Falha ao habilitar Managed Identity" -ForegroundColor Red
        Write-Host "Erro: $miOutput" -ForegroundColor Red
        exit 1
    }
    $ErrorActionPreference = "Stop"
}
Write-Host ""

# 2. Aguardar propagação
Write-Host "[INFO] Aguardando 10 segundos para propagação..." -ForegroundColor Yellow
Start-Sleep -Seconds 10
Write-Host ""

# 3. Configurar permissões no Key Vault
Write-Host "=== 2. Configurando Permissões no Key Vault ===" -ForegroundColor Cyan
Write-Host "[INFO] Concedendo permissões 'get' e 'list' para secrets..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$kvPolicy = az keyvault set-policy `
    --name $KeyVault `
    --object-id $principalId `
    --secret-permissions get list 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Permissões configuradas no Key Vault" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Falha ao configurar permissões (pode já estar configurado)" -ForegroundColor Yellow
    Write-Host "Saída: $kvPolicy" -ForegroundColor Gray
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 4. Verificar permissões
Write-Host "=== 3. Verificando Permissões ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$permissions = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query "properties.accessPolicies[?objectId=='$principalId'].permissions.secrets" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($permissions) {
    Write-Host "[OK] Permissões encontradas:" -ForegroundColor Green
    Write-Host "  Secrets: $($permissions -join ', ')" -ForegroundColor Gray
    
    $hasGet = $permissions -contains "get"
    $hasList = $permissions -contains "list"
    
    if (-not $hasGet -or -not $hasList) {
        Write-Host "[AVISO] Permissões incompletas!" -ForegroundColor Yellow
        if (-not $hasGet) {
            Write-Host "  [FALTA] 'get'" -ForegroundColor Red
        }
        if (-not $hasList) {
            Write-Host "  [FALTA] 'list'" -ForegroundColor Red
        }
    }
} else {
    Write-Host "[AVISO] Nenhuma permissão encontrada. Tente novamente após alguns segundos." -ForegroundColor Yellow
}
Write-Host ""

# 5. Resumo
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "[OK] Managed Identity habilitada: $principalId" -ForegroundColor Green
Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
Write-Host "  1. Aguarde alguns minutos para propagação completa" -ForegroundColor Gray
Write-Host "  2. Teste se os secrets estão sendo resolvidos:" -ForegroundColor Gray
Write-Host "     .\infra\verify_openai_key.ps1" -ForegroundColor Gray
Write-Host "  3. Se necessário, reinicie o Container App:" -ForegroundColor Gray
Write-Host "     az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision <latest>" -ForegroundColor Gray
Write-Host ""
