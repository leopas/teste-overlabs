# Script de auditoria completa para diagnosticar problemas de acesso ao volume

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== AUDITORIA COMPLETA: Acesso ao Volume ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
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
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

$issues = @()
$warnings = @()

# ==========================================
# 1. VERIFICAR VOLUME NO ENVIRONMENT
# ==========================================
Write-Host "=== 1. Volume no Environment ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{name:name,accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName,accessMode:properties.azureFile.accessMode}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if ($volumeInfo) {
    $volumeObj = $volumeInfo | ConvertFrom-Json
    Write-Host "[OK] Volume 'documents-storage' existe no Environment" -ForegroundColor Green
    Write-Host "  Storage Account: $($volumeObj.accountName)" -ForegroundColor Gray
    Write-Host "  File Share: $($volumeObj.shareName)" -ForegroundColor Gray
    Write-Host "  Access Mode: $($volumeObj.accessMode)" -ForegroundColor Gray
    $storageAccount = $volumeObj.accountName
    $shareName = $volumeObj.shareName
} else {
    Write-Host "[ERRO] Volume 'documents-storage' NÃO existe no Environment!" -ForegroundColor Red
    $issues += "Volume não existe no Environment"
    Write-Host ""
    exit 1
}
Write-Host ""

# ==========================================
# 2. VERIFICAR VOLUME DEFINIDO NO CONTAINER APP
# ==========================================
Write-Host "=== 2. Volume Definido no Container App ===" -ForegroundColor Cyan
$appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template" -o json | ConvertFrom-Json

$hasVolume = $false
if ($appConfig.volumes) {
    foreach ($vol in $appConfig.volumes) {
        if ($vol.name -eq "documents-storage") {
            $hasVolume = $true
            Write-Host "[OK] Volume 'documents-storage' está definido no Container App" -ForegroundColor Green
            Write-Host "  Nome: $($vol.name)" -ForegroundColor Gray
            Write-Host "  Tipo: $($vol.storageType)" -ForegroundColor Gray
            Write-Host "  Storage Name: $($vol.storageName)" -ForegroundColor Gray
            
            if ($vol.storageType -ne "AzureFile") {
                $issues += "Volume tem tipo incorreto: $($vol.storageType) (esperado: AzureFile)"
            }
            if ($vol.storageName -ne "documents-storage") {
                $warnings += "Storage name não corresponde: $($vol.storageName)"
            }
            break
        }
    }
}

if (-not $hasVolume) {
    Write-Host "[ERRO] Volume 'documents-storage' NÃO está definido no Container App!" -ForegroundColor Red
    $issues += "Volume não definido no Container App"
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1" -ForegroundColor Yellow
}
Write-Host ""

# ==========================================
# 3. VERIFICAR VOLUME MOUNT
# ==========================================
Write-Host "=== 3. Volume Mount no Container ===" -ForegroundColor Cyan
$containerConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json

$hasVolumeMount = $false
if ($containerConfig.volumeMounts) {
    foreach ($vm in $containerConfig.volumeMounts) {
        if ($vm.volumeName -eq "documents-storage") {
            $hasVolumeMount = $true
            Write-Host "[OK] Volume mount está configurado" -ForegroundColor Green
            Write-Host "  Volume Name: $($vm.volumeName)" -ForegroundColor Gray
            Write-Host "  Mount Path: $($vm.mountPath)" -ForegroundColor Gray
            
            if ($vm.mountPath -ne "/app/DOC-IA") {
                $warnings += "Mount path diferente do esperado: $($vm.mountPath) (esperado: /app/DOC-IA)"
            }
            break
        }
    }
}

if (-not $hasVolumeMount) {
    Write-Host "[ERRO] Volume mount NÃO está configurado!" -ForegroundColor Red
    $issues += "Volume mount não configurado"
}
Write-Host ""

# ==========================================
# 4. VERIFICAR MANAGED IDENTITY
# ==========================================
Write-Host "=== 4. Managed Identity ===" -ForegroundColor Cyan
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if ($identity -and $identity.type -eq "SystemAssigned") {
    $principalId = $identity.principalId
    Write-Host "[OK] Managed Identity está habilitada (SystemAssigned)" -ForegroundColor Green
    Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity NÃO está habilitada ou não é SystemAssigned!" -ForegroundColor Red
    $issues += "Managed Identity não habilitada"
    $principalId = $null
}
Write-Host ""

# ==========================================
# 5. VERIFICAR PERMISSÕES NO STORAGE ACCOUNT
# ==========================================
Write-Host "=== 5. Permissões no Storage Account ===" -ForegroundColor Cyan
if ($principalId) {
    $storageAccountId = az storage account show --name $storageAccount --resource-group $ResourceGroup --query id -o tsv
    $requiredRole = "Storage File Data SMB Share Contributor"
    
    $ErrorActionPreference = "Continue"
    $roleAssignments = az role assignment list `
        --assignee $principalId `
        --scope $storageAccountId `
        --query "[?roleDefinitionName=='$requiredRole']" -o json 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($roleAssignments -and ($roleAssignments | ConvertFrom-Json).Count -gt 0) {
        Write-Host "[OK] Container App tem permissão '$requiredRole' no Storage Account" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Container App NÃO tem permissão '$requiredRole' no Storage Account!" -ForegroundColor Red
        $issues += "Falta permissão no Storage Account"
        Write-Host "[INFO] Execute: .\infra\check_storage_permissions.ps1" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] Não é possível verificar permissões (Managed Identity não habilitada)" -ForegroundColor Yellow
    $warnings += "Não foi possível verificar permissões"
}
Write-Host ""

# ==========================================
# 6. VERIFICAR ARQUIVOS NO FILE SHARE
# ==========================================
Write-Host "=== 6. Arquivos no File Share ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$storageKey = az storage account keys list --account-name $storageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv 2>$null
$files = az storage file list `
    --account-name $storageAccount `
    --account-key $storageKey `
    --share-name $shareName `
    --query "[].name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($files) {
    $fileCount = ($files | Measure-Object).Count
    Write-Host "[OK] File Share contém $fileCount arquivo(s)" -ForegroundColor Green
    Write-Host "  Primeiros arquivos:" -ForegroundColor Gray
    $files | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
} else {
    Write-Host "[AVISO] File Share está vazio!" -ForegroundColor Yellow
    $warnings += "File Share está vazio - execute: .\infra\mount_docs_volume.ps1 -UploadDocs"
}
Write-Host ""

# ==========================================
# 7. VERIFICAR REVISION ATIVA
# ==========================================
Write-Host "=== 7. Revision Ativa ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$activeRevisions = az containerapp revision list `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "[?properties.active==\`true\`]" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if ($activeRevisions) {
    $activeRevision = $activeRevisions[0]
    Write-Host "[OK] Revision ativa encontrada" -ForegroundColor Green
    Write-Host "  Nome: $($activeRevision.name)" -ForegroundColor Gray
    Write-Host "  Estado: $($activeRevision.properties.provisioningState)" -ForegroundColor Gray
    Write-Host "  Criada: $($activeRevision.properties.createdTime)" -ForegroundColor Gray
    
    # Verificar se a revision tem o volume mount
    $revisionHasVolume = $false
    if ($activeRevision.properties.template.volumes) {
        foreach ($vol in $activeRevision.properties.template.volumes) {
            if ($vol.name -eq "documents-storage") {
                $revisionHasVolume = $true
                break
            }
        }
    }
    
    if (-not $revisionHasVolume) {
        Write-Host "[AVISO] Revision ativa NÃO tem volume definido!" -ForegroundColor Yellow
        $warnings += "Revision ativa não tem volume - pode precisar de nova revision"
    }
} else {
    Write-Host "[AVISO] Não foi possível obter revision ativa" -ForegroundColor Yellow
}
Write-Host ""

# ==========================================
# 8. VERIFICAR ACESSO NO CONTAINER (TESTE REAL)
# ==========================================
Write-Host "=== 8. Teste de Acesso no Container ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$testOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "ls -la /app 2>&1 || echo 'ERROR'" 2>&1

if ($testOutput -match "ERROR" -or $LASTEXITCODE -ne 0) {
    Write-Host "[AVISO] Não foi possível executar comando no container" -ForegroundColor Yellow
} else {
    Write-Host "[INFO] Conteúdo de /app:" -ForegroundColor Gray
    Write-Host $testOutput
}

# Teste específico do diretório
$testDocIA = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' && ls -la /app/DOC-IA 2>&1 | head -10 || echo 'NOT_FOUND'" 2>&1

if ($testDocIA -match "EXISTS") {
    Write-Host "[OK] /app/DOC-IA existe e está acessível!" -ForegroundColor Green
    Write-Host $testDocIA
} else {
    Write-Host "[ERRO] /app/DOC-IA NÃO está acessível no container!" -ForegroundColor Red
    $issues += "/app/DOC-IA não acessível no container"
}
$ErrorActionPreference = "Stop"
Write-Host ""

# ==========================================
# 9. VERIFICAR LOGS DO CONTAINER (ERROS DE MONTAGEM)
# ==========================================
Write-Host "=== 9. Logs do Container (últimas 50 linhas) ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$logs = az containerapp logs show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --tail 50 `
    --type console 2>$null

if ($logs) {
    # Procurar por erros relacionados a volume/mount
    $volumeErrors = $logs | Select-String -Pattern "volume|mount|storage|file|DOC-IA" -CaseSensitive:$false
    if ($volumeErrors) {
        Write-Host "[AVISO] Possíveis erros relacionados a volume encontrados nos logs:" -ForegroundColor Yellow
        $volumeErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } else {
        Write-Host "[INFO] Nenhum erro relacionado a volume encontrado nos logs recentes" -ForegroundColor Gray
    }
} else {
    Write-Host "[AVISO] Não foi possível obter logs" -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"
Write-Host ""

# ==========================================
# RESUMO E RECOMENDAÇÕES
# ==========================================
Write-Host "=== RESUMO DA AUDITORIA ===" -ForegroundColor Cyan
Write-Host ""

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "[OK] Tudo parece estar configurado corretamente!" -ForegroundColor Green
    Write-Host "[INFO] Se o volume ainda não está acessível, tente:" -ForegroundColor Cyan
    Write-Host "  1. Reiniciar o Container App: .\infra\restart_and_verify_volume.ps1" -ForegroundColor Gray
    Write-Host "  2. Aguardar alguns minutos e verificar novamente" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Problemas encontrados:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  ✗ $issue" -ForegroundColor Red
    }
    
    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "[AVISO] Avisos:" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host "  ⚠ $warning" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-Host "[INFO] Ações recomendadas:" -ForegroundColor Cyan
    
    if ($issues -contains "Volume não definido no Container App" -or $issues -contains "Volume mount não configurado") {
        Write-Host "  1. Execute: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
    }
    
    if ($issues -contains "Falta permissão no Storage Account") {
        Write-Host "  2. Execute: .\infra\check_storage_permissions.ps1" -ForegroundColor Gray
    }
    
    if ($issues -contains "Managed Identity não habilitada") {
        Write-Host "  3. Execute: .\infra\check_storage_permissions.ps1 (habilitará Managed Identity)" -ForegroundColor Gray
    }
    
    if ($warnings -contains "File Share está vazio") {
        Write-Host "  4. Execute: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
    }
    
    if ($issues -contains "/app/DOC-IA não acessível no container") {
        Write-Host "  5. Execute: .\infra\restart_and_verify_volume.ps1" -ForegroundColor Gray
    }
}

Write-Host ""
