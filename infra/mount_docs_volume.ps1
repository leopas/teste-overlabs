# Script para montar o volume de documentos no Container App existente
# Verifica se o volume está configurado e monta se necessário

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [switch]$UploadDocs
)

$ErrorActionPreference = "Stop"

Write-Host "=== Montar Volume de Documentos no Container App ===" -ForegroundColor Cyan
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

# 1. Verificar Storage Account e File Share
Write-Host "[INFO] Verificando Storage Account e File Share..." -ForegroundColor Yellow
$storageAccounts = az storage account list --resource-group $ResourceGroup --query "[].name" -o tsv
if (-not $storageAccounts) {
    Write-Host "[ERRO] Nenhum Storage Account encontrado no Resource Group" -ForegroundColor Red
    exit 1
}

$StorageAccount = ($storageAccounts | Select-Object -First 1)
Write-Host "[OK] Storage Account: $StorageAccount" -ForegroundColor Green

$storageKey = az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
$DocsFileShare = "documents"

$ErrorActionPreference = "Continue"
$shareExists = az storage share show --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando File Share '$DocsFileShare'..." -ForegroundColor Yellow
    az storage share create --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare --quota 10 | Out-Null
    Write-Host "[OK] File Share criado" -ForegroundColor Green
} else {
    Write-Host "[OK] File Share '$DocsFileShare' já existe" -ForegroundColor Green
}
Write-Host ""

# 2. Configurar volume no Environment
Write-Host "[INFO] Configurando volume 'documents-storage' no Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeExists = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando volume no Environment..." -ForegroundColor Yellow
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name documents-storage `
        --azure-file-account-name $StorageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $DocsFileShare `
        --access-mode ReadWrite 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Volume configurado no Environment" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao configurar volume no Environment" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Volume já existe no Environment" -ForegroundColor Green
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 3. Verificar se o Container App já tem o volume montado
Write-Host "[INFO] Verificando se Container App tem volume montado..." -ForegroundColor Yellow
$appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json

$hasVolumeMount = $false
if ($appConfig.volumeMounts) {
    foreach ($vm in $appConfig.volumeMounts) {
        if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
            $hasVolumeMount = $true
            Write-Host "[OK] Volume já está montado em /app/DOC-IA" -ForegroundColor Green
            break
        }
    }
}

if (-not $hasVolumeMount) {
    Write-Host "[INFO] Volume não está montado. Adicionando volume mount..." -ForegroundColor Yellow
    
    # Obter configuração atual do Container App
    $currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json | ConvertFrom-Json
    
    # Verificar se já tem volumes definidos
    $volumes = @()
    if ($currentConfig.properties.template.volumes) {
        $volumes = $currentConfig.properties.template.volumes
    }
    
    # Adicionar volume se não existir
    $hasVolume = $false
    foreach ($vol in $volumes) {
        if ($vol.name -eq "documents-storage") {
            $hasVolume = $true
            break
        }
    }
    
    if (-not $hasVolume) {
        $volumes += @{
            name = "documents-storage"
            storageType = "AzureFile"
            storageName = "documents-storage"
        }
    }
    
    # Adicionar volume mount no container
    $volumeMounts = @()
    if ($currentConfig.properties.template.containers[0].volumeMounts) {
        $volumeMounts = $currentConfig.properties.template.containers[0].volumeMounts
    }
    
    $volumeMounts += @{
        volumeName = "documents-storage"
        mountPath = "/app/DOC-IA"
    }
    
    # Atualizar Container App usando YAML
    $envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv
    
    # Construir YAML para atualização
    $volumesYaml = ""
    foreach ($vol in $volumes) {
        $volumesYaml += "    - name: $($vol.name)`n      storageType: $($vol.storageType)`n      storageName: $($vol.storageName)`n"
    }
    
    $volumeMountsYaml = ""
    foreach ($vm in $volumeMounts) {
        $volumeMountsYaml += "      - volumeName: $($vm.volumeName)`n        mountPath: $($vm.mountPath)`n"
    }
    
    # Obter env vars existentes
    $envVars = @()
    if ($currentConfig.properties.template.containers[0].env) {
        foreach ($env in $currentConfig.properties.template.containers[0].env) {
            $envVars += "$($env.name)=$($env.value)"
        }
    }
    
    # Garantir DOCS_ROOT
    $hasDocsRoot = $false
    foreach ($envVar in $envVars) {
        if ($envVar -match "^DOCS_ROOT=") {
            $hasDocsRoot = $true
            break
        }
    }
    if (-not $hasDocsRoot) {
        $envVars += "DOCS_ROOT=/app/DOC-IA"
    }
    
    $envVarsYaml = ""
    foreach ($envVar in $envVars) {
        $parts = $envVar -split '=', 2
        $name = $parts[0]
        $value = $parts[1]
        $value = $value -replace '"', '\"'
        $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
    }
    
    $yamlContent = @"
properties:
  environmentId: $envId
  template:
    containers:
    - name: $($currentConfig.properties.template.containers[0].name)
      image: $($currentConfig.properties.template.containers[0].image)
      env:
$envVarsYaml      volumeMounts:
$volumeMountsYaml    volumes:
$volumesYaml
"@
    
    $yamlFile = [System.IO.Path]::GetTempFileName() + ".yaml"
    $yamlContent | Out-File -FilePath $yamlFile -Encoding utf8 -NoNewline
    
    Write-Host "[INFO] Atualizando Container App com volume mount..." -ForegroundColor Yellow
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --yaml $yamlFile | Out-Null
    
    Remove-Item $yamlFile -Force
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Container App atualizado com volume mount" -ForegroundColor Green
        Write-Host "[INFO] Aguardando 10s para a atualização ser aplicada..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    } else {
        Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# 4. Upload de documentos se solicitado
if ($UploadDocs) {
    Write-Host "[INFO] Fazendo upload dos documentos locais para o Azure File Share..." -ForegroundColor Yellow
    $localDocsPath = "DOC-IA"
    
    if (-not (Test-Path $localDocsPath)) {
        Write-Host "[AVISO] Pasta local '$localDocsPath' não encontrada. Pulando upload." -ForegroundColor Yellow
    } else {
        $ErrorActionPreference = "Continue"
        az storage file upload-batch `
            --account-name $StorageAccount `
            --account-key $storageKey `
            --destination $DocsFileShare `
            --source $localDocsPath `
            --overwrite `
            --connection-string "DefaultEndpointsProtocol=https;AccountName=$StorageAccount;AccountKey=$storageKey;EndpointSuffix=core.windows.net" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Documentos enviados para o Azure File Share" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Falha ao enviar documentos. Tente novamente ou faça upload manual." -ForegroundColor Yellow
        }
        $ErrorActionPreference = "Stop"
    }
    Write-Host ""
}

# 5. Verificar se o volume está acessível no container
Write-Host "[INFO] Verificando se /app/DOC-IA está acessível no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && ls -la /app/DOC-IA | head -10 || echo 'NOT_FOUND'" 2>&1

if ($checkOutput -match "NOT_FOUND") {
    Write-Host "[AVISO] /app/DOC-IA ainda não está acessível. Pode levar alguns minutos para o volume ser montado." -ForegroundColor Yellow
    Write-Host "[INFO] Aguarde alguns minutos e execute novamente para verificar." -ForegroundColor Yellow
} else {
    Write-Host "[OK] /app/DOC-IA está acessível no container" -ForegroundColor Green
    Write-Host $checkOutput
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Se os documentos não foram enviados, execute: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
Write-Host "  2. Execute a ingestão: .\infra\run_ingest_in_container.ps1" -ForegroundColor Gray
Write-Host ""
