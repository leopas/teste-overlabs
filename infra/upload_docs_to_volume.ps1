# Script para fazer upload dos documentos da pasta DOC-IA para o Azure File Share
# Os arquivos ficam disponíveis no volume montado no container

param(
    [string]$ResourceGroup = $null,
    [string]$Environment = $null,
    [string]$LocalDocsPath = "DOC-IA"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Upload de Documentos para Azure File Share ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $Environment) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] Pasta local: $LocalDocsPath" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar se a pasta local existe
if (-not (Test-Path $LocalDocsPath)) {
    Write-Host "[ERRO] Pasta local '$LocalDocsPath' nao encontrada!" -ForegroundColor Red
    Write-Host "[INFO] Crie a pasta DOC-IA com os documentos ou especifique outro caminho com -LocalDocsPath" -ForegroundColor Cyan
    exit 1
}

# 2. Obter informações do volume no Environment
Write-Host "[1/4] Obtendo informacoes do volume..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if (-not $volumeInfo) {
    Write-Host "[ERRO] Volume 'documents-storage' nao encontrado no Environment!" -ForegroundColor Red
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 para criar o volume" -ForegroundColor Cyan
    exit 1
}

$volumeObj = $volumeInfo | ConvertFrom-Json
$StorageAccount = $volumeObj.accountName
$DocsFileShare = $volumeObj.shareName

Write-Host "[OK] Volume encontrado" -ForegroundColor Green
Write-Host "  Storage Account: $StorageAccount" -ForegroundColor Gray
Write-Host "  File Share: $DocsFileShare" -ForegroundColor Gray
Write-Host ""

# 3. Obter chave do Storage Account
Write-Host "[2/4] Obtendo chave do Storage Account..." -ForegroundColor Yellow
$storageKey = az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv

if (-not $storageKey) {
    Write-Host "[ERRO] Falha ao obter chave do Storage Account!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Chave obtida" -ForegroundColor Green
Write-Host ""

# 4. Listar arquivos locais
Write-Host "[3/4] Listando arquivos locais..." -ForegroundColor Yellow
$localFiles = Get-ChildItem -Path $LocalDocsPath -File -Recurse
$fileCount = $localFiles.Count

if ($fileCount -eq 0) {
    Write-Host "[AVISO] Nenhum arquivo encontrado em '$LocalDocsPath'" -ForegroundColor Yellow
    exit 0
}

Write-Host "[OK] Encontrados $fileCount arquivo(s)" -ForegroundColor Green
Write-Host ""

# 5. Fazer upload dos arquivos
Write-Host "[4/4] Fazendo upload dos arquivos..." -ForegroundColor Yellow
Write-Host ""

$ErrorActionPreference = "Continue"

# Tentar upload usando upload-batch primeiro (mais rápido)
Write-Host "[INFO] Tentando upload em lote (mais rapido)..." -ForegroundColor Cyan
$batchOutput = az storage file upload-batch `
    --account-name $StorageAccount `
    --account-key $storageKey `
    --destination $DocsFileShare `
    --source $LocalDocsPath `
    --overwrite 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Upload em lote concluido com sucesso!" -ForegroundColor Green
    Write-Host ""
    
    # Verificar arquivos enviados
    $uploadedFiles = az storage file list `
        --account-name $StorageAccount `
        --account-key $storageKey `
        --share-name $DocsFileShare `
        --query "[].name" -o tsv 2>$null
    
    if ($uploadedFiles) {
        $uploadedCount = ($uploadedFiles | Measure-Object).Count
        Write-Host "[OK] $uploadedCount arquivo(s) no File Share" -ForegroundColor Green
        Write-Host "  Primeiros arquivos:" -ForegroundColor Gray
        $uploadedFiles | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
} else {
    Write-Host "[AVISO] Upload em lote falhou. Tentando arquivo por arquivo..." -ForegroundColor Yellow
    Write-Host ""
    
    # Fallback: upload arquivo por arquivo
    $successCount = 0
    $failCount = 0
    
    foreach ($file in $localFiles) {
        $relativePath = $file.FullName.Substring((Resolve-Path $LocalDocsPath).Path.Length + 1)
        $relativePath = $relativePath.Replace('\', '/')
        
        # Criar diretório se necessário
        $dirPath = Split-Path -Path $relativePath -Parent
        if ($dirPath -and $dirPath -ne ".") {
            az storage directory create `
                --account-name $StorageAccount `
                --account-key $storageKey `
                --share-name $DocsFileShare `
                --name $dirPath 2>&1 | Out-Null
        }
        
        # Tentar remover arquivo existente (ignorar erro se não existir)
        az storage file delete `
            --account-name $StorageAccount `
            --account-key $storageKey `
            --share-name $DocsFileShare `
            --path $relativePath 2>&1 | Out-Null
        
        # Upload do arquivo
        $uploadError = az storage file upload `
            --account-name $StorageAccount `
            --account-key $storageKey `
            --share-name $DocsFileShare `
            --source $file.FullName `
            --path $relativePath 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $successCount++
            Write-Host "  [OK] $relativePath" -ForegroundColor Green
        } else {
            $failCount++
            Write-Host "  [ERRO] $relativePath" -ForegroundColor Red
            if ($uploadError) {
                $errorMsg = ($uploadError | Out-String).Trim()
                $errorLines = $errorMsg -split "`n" | Where-Object { $_ -match "ERROR|error|Error" } | Select-Object -First 1
                if ($errorLines) {
                    Write-Host "    $errorLines" -ForegroundColor DarkRed
                }
            }
        }
    }
    
    Write-Host ""
    if ($successCount -gt 0) {
        Write-Host "[OK] $successCount arquivo(s) enviado(s) com sucesso" -ForegroundColor Green
    }
    if ($failCount -gt 0) {
        Write-Host "[ERRO] $failCount arquivo(s) falharam no upload" -ForegroundColor Red
    }
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Upload Concluido ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Os arquivos estao disponiveis no volume montado em /app/DOC-IA no container" -ForegroundColor Cyan
Write-Host "[INFO] Execute a ingestao para indexar os documentos:" -ForegroundColor Cyan
Write-Host "  .\infra\run_ingest_in_container.ps1" -ForegroundColor Gray
Write-Host ""
