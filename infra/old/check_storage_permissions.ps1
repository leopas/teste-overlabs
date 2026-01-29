# Script para verificar e corrigir permissões do Container App no Storage Account

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Permissões do Container App no Storage Account ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup, -ApiAppName e -Environment." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $ApiAppName) {
        $ApiAppName = $state.apiAppName
    }
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar Managed Identity do Container App
Write-Host "[INFO] Verificando Managed Identity do Container App..." -ForegroundColor Yellow
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if (-not $identity -or -not $identity.type -or $identity.type -ne "SystemAssigned") {
    Write-Host "[AVISO] Managed Identity não está habilitada ou não é SystemAssigned" -ForegroundColor Yellow
    Write-Host "[INFO] Habilitando Managed Identity..." -ForegroundColor Cyan
    
    az containerapp identity assign `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --system-assigned | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
        Start-Sleep -Seconds 5
        
        # Obter identity novamente
        $identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json
    } else {
        Write-Host "[ERRO] Falha ao habilitar Managed Identity" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Managed Identity está habilitada (SystemAssigned)" -ForegroundColor Green
}

$principalId = $identity.principalId
Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
Write-Host ""

# 2. Obter Storage Account do volume
Write-Host "[INFO] Obtendo Storage Account do volume..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if (-not $volumeInfo) {
    Write-Host "[ERRO] Volume 'documents-storage' não encontrado no Environment!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 para criar o volume" -ForegroundColor Yellow
    exit 1
}

$volumeObj = $volumeInfo | ConvertFrom-Json
$storageAccount = $volumeObj.accountName
Write-Host "[OK] Storage Account: $storageAccount" -ForegroundColor Green
Write-Host "  File Share: $($volumeObj.shareName)" -ForegroundColor Gray
Write-Host ""

# 3. Obter Resource ID do Storage Account
Write-Host "[INFO] Obtendo Resource ID do Storage Account..." -ForegroundColor Yellow
$storageAccountId = az storage account show `
    --name $storageAccount `
    --resource-group $ResourceGroup `
    --query id -o tsv

if (-not $storageAccountId) {
    Write-Host "[ERRO] Storage Account não encontrado!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Storage Account ID: $storageAccountId" -ForegroundColor Green
Write-Host ""

# 4. Verificar permissões no Storage Account
Write-Host "[INFO] Verificando permissões no Storage Account..." -ForegroundColor Yellow

# Role necessária para Azure Files: "Storage File Data SMB Share Contributor"
$requiredRole = "Storage File Data SMB Share Contributor"
$subscriptionId = az account show --query id -o tsv

$ErrorActionPreference = "Continue"
$roleAssignments = az role assignment list `
    --assignee $principalId `
    --scope $storageAccountId `
    --query "[?roleDefinitionName=='$requiredRole']" -o json 2>$null
$ErrorActionPreference = "Stop"

if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) {
    Write-Host "[OK] Container App já tem permissão '$requiredRole' no Storage Account" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Container App NÃO tem permissão '$requiredRole' no Storage Account" -ForegroundColor Yellow
    Write-Host "[INFO] Concedendo permissão..." -ForegroundColor Cyan
    
    az role assignment create `
        --assignee $principalId `
        --role $requiredRole `
        --scope $storageAccountId 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Permissão concedida com sucesso!" -ForegroundColor Green
        Write-Host "[INFO] Aguardando 5s para a permissão ser propagada..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    } else {
        Write-Host "[AVISO] Pode já ter permissão ou erro ao conceder. Verificando novamente..." -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        $roleAssignments = az role assignment list `
            --assignee $principalId `
            --scope $storageAccountId `
            --query "[?roleDefinitionName=='$requiredRole']" -o json 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) {
            Write-Host "[OK] Permissão confirmada" -ForegroundColor Green
        } else {
            Write-Host "[ERRO] Falha ao conceder permissão. Tente manualmente:" -ForegroundColor Red
            Write-Host "  az role assignment create --assignee $principalId --role '$requiredRole' --scope $storageAccountId" -ForegroundColor Gray
        }
    }
}
Write-Host ""

# 5. Verificar se o volume está acessível (teste final)
Write-Host "[INFO] Verificando se o volume está acessível no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$testOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' && ls -la /app/DOC-IA | head -5 || echo 'NOT_FOUND'" 2>&1

if ($testOutput -match "EXISTS") {
    Write-Host "[OK] Volume está acessível no container!" -ForegroundColor Green
    Write-Host $testOutput
} else {
    Write-Host "[AVISO] Volume ainda não está acessível" -ForegroundColor Yellow
    Write-Host "[INFO] Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Permissões foram concedidas mas o container precisa ser reiniciado" -ForegroundColor Gray
    Write-Host "  2. Volume mount precisa ser reconfigurado" -ForegroundColor Gray
    Write-Host "  3. File Share está vazio" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Tente:" -ForegroundColor Cyan
    Write-Host "  1. Reiniciar o Container App: az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup" -ForegroundColor Gray
    Write-Host "  2. Aguardar alguns minutos e verificar novamente" -ForegroundColor Gray
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Managed Identity: $(if ($identity.type -eq 'SystemAssigned') { '✓' } else { '✗' })" -ForegroundColor $(if ($identity.type -eq 'SystemAssigned') { 'Green' } else { 'Red' })
Write-Host "Permissão no Storage: $(if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) { '✓' } else { '✗' })" -ForegroundColor $(if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) { 'Green' } else { 'Red' })
Write-Host "Volume acessível: $(if ($testOutput -match 'EXISTS') { '✓' } else { '✗' })" -ForegroundColor $(if ($testOutput -match 'EXISTS') { 'Green' } else { 'Red' })
Write-Host ""
