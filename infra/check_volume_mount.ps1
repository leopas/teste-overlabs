# Script para verificar se o volume está mapeado corretamente no Container App

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Mapeamento de Volume no Container App ===" -ForegroundColor Cyan
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

# 1. Verificar se o volume existe no Environment
Write-Host "[INFO] Verificando volume 'documents-storage' no Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{name:name,accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName,accessMode:properties.azureFile.accessMode}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if (-not $volumeInfo) {
    Write-Host "[ERRO] Volume 'documents-storage' não encontrado no Environment!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 para criar o volume" -ForegroundColor Yellow
    exit 1
}

$volumeObj = $volumeInfo | ConvertFrom-Json
Write-Host "[OK] Volume existe no Environment" -ForegroundColor Green
Write-Host "  Nome: $($volumeObj.name)" -ForegroundColor Gray
Write-Host "  Storage Account: $($volumeObj.accountName)" -ForegroundColor Gray
Write-Host "  File Share: $($volumeObj.shareName)" -ForegroundColor Gray
Write-Host "  Access Mode: $($volumeObj.accessMode)" -ForegroundColor Gray
Write-Host ""

# 2. Verificar se o Container App tem o volume definido
Write-Host "[INFO] Verificando volumes definidos no Container App..." -ForegroundColor Yellow
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
            break
        }
    }
}

if (-not $hasVolume) {
    Write-Host "[ERRO] Volume 'documents-storage' NÃO está definido no Container App!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 para adicionar o volume" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host ""

# 3. Verificar se o Container App tem o volume mount
Write-Host "[INFO] Verificando volume mounts no Container App..." -ForegroundColor Yellow
$containerConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json

$hasVolumeMount = $false
if ($containerConfig.volumeMounts) {
    foreach ($vm in $containerConfig.volumeMounts) {
        if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
            $hasVolumeMount = $true
            Write-Host "[OK] Volume mount está configurado" -ForegroundColor Green
            Write-Host "  Volume Name: $($vm.volumeName)" -ForegroundColor Gray
            Write-Host "  Mount Path: $($vm.mountPath)" -ForegroundColor Gray
            break
        }
    }
}

if (-not $hasVolumeMount) {
    Write-Host "[ERRO] Volume mount NÃO está configurado no Container App!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 para adicionar o volume mount" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host ""

# 4. Verificar se o diretório existe no container (teste real)
Write-Host "[INFO] Verificando se /app/DOC-IA existe no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' && ls -la /app/DOC-IA | head -10 || echo 'NOT_FOUND'" 2>&1

if ($checkOutput -match "EXISTS") {
    Write-Host "[OK] Diretório /app/DOC-IA existe no container!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Conteúdo do diretório:" -ForegroundColor Cyan
    Write-Host $checkOutput
    Write-Host ""
} else {
    Write-Host "[AVISO] Diretório /app/DOC-IA não está acessível no container" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Volume foi adicionado mas o container precisa ser reiniciado" -ForegroundColor Gray
    Write-Host "  2. File Share está vazio (não há documentos)" -ForegroundColor Gray
    Write-Host "  3. Problema com montagem do volume" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Tente:" -ForegroundColor Cyan
    Write-Host "  1. Aguardar alguns minutos e verificar novamente" -ForegroundColor Gray
    Write-Host "  2. Reiniciar o Container App: az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup" -ForegroundColor Gray
    Write-Host "  3. Fazer upload dos documentos: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
    Write-Host ""
}
$ErrorActionPreference = "Stop"

# 5. Verificar se há arquivos no File Share
Write-Host "[INFO] Verificando arquivos no File Share..." -ForegroundColor Yellow
$storageAccount = $volumeObj.accountName
$shareName = $volumeObj.shareName

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
    if ($fileCount -gt 5) {
        Write-Host "    ... e mais $($fileCount - 5) arquivo(s)" -ForegroundColor Gray
    }
} else {
    Write-Host "[AVISO] File Share está vazio!" -ForegroundColor Yellow
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 -UploadDocs para fazer upload dos documentos" -ForegroundColor Cyan
}
Write-Host ""

Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host ""

if ($hasVolume -and $hasVolumeMount -and ($checkOutput -match "EXISTS")) {
    Write-Host "[OK] Tudo configurado corretamente!" -ForegroundColor Green
    Write-Host "  Volume existe no Environment: ✓" -ForegroundColor Green
    Write-Host "  Volume definido no Container App: ✓" -ForegroundColor Green
    Write-Host "  Volume mount configurado: ✓" -ForegroundColor Green
    Write-Host "  Diretório acessível no container: ✓" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Você pode executar a ingestão:" -ForegroundColor Cyan
    Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Algumas configurações estão faltando:" -ForegroundColor Yellow
    Write-Host "  Volume existe no Environment: $(if ($hasVolume) { '✓' } else { '✗' })" -ForegroundColor $(if ($hasVolume) { 'Green' } else { 'Red' })
    Write-Host "  Volume definido no Container App: $(if ($hasVolume) { '✓' } else { '✗' })" -ForegroundColor $(if ($hasVolume) { 'Green' } else { 'Red' })
    Write-Host "  Volume mount configurado: $(if ($hasVolumeMount) { '✓' } else { '✗' })" -ForegroundColor $(if ($hasVolumeMount) { 'Green' } else { 'Red' })
    Write-Host "  Diretório acessível no container: $(if ($checkOutput -match 'EXISTS') { '✓' } else { '✗' })" -ForegroundColor $(if ($checkOutput -match 'EXISTS') { 'Green' } else { 'Red' })
    Write-Host ""
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 -UploadDocs para corrigir" -ForegroundColor Cyan
}

Write-Host ""
