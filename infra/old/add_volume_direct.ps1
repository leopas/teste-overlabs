# Script para adicionar volume diretamente usando comandos Azure CLI
# Este script usa uma abordagem mais direta que o YAML

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionar Volume Diretamente ao Container App ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se nao fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
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
Write-Host "[INFO] Verificando volume no Environment..." -ForegroundColor Yellow
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
    Write-Host "[INFO] Execute: .\infra\mount_docs_volume.ps1 primeiro" -ForegroundColor Yellow
    exit 1
}

$volumeObj = $volumeInfo | ConvertFrom-Json
Write-Host "[OK] Volume existe no Environment" -ForegroundColor Green
Write-Host ""

# 2. Obter configuracao atual do Container App
Write-Host "[INFO] Obtendo configuracao atual do Container App..." -ForegroundColor Yellow
$currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json | ConvertFrom-Json

# 3. Construir JSON completo para atualizacao
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv

# Obter env vars existentes
$envVars = @()
if ($currentConfig.properties.template.containers[0].env) {
    foreach ($env in $currentConfig.properties.template.containers[0].env) {
        $envVars += @{
            name = $env.name
            value = $env.value
        }
    }
}

# Garantir DOCS_ROOT
$hasDocsRoot = $false
foreach ($envVar in $envVars) {
    if ($envVar.name -eq "DOCS_ROOT") {
        $hasDocsRoot = $true
        break
    }
}
if (-not $hasDocsRoot) {
    $envVars += @{
        name = "DOCS_ROOT"
        value = "/app/DOC-IA"
    }
}

# Construir volumes
$volumes = @()
if ($currentConfig.properties.template.volumes) {
    foreach ($vol in $currentConfig.properties.template.volumes) {
        $volumes += @{
            name = $vol.name
            storageType = $vol.storageType
            storageName = $vol.storageName
        }
    }
}

# Adicionar volume se nao existir
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

# Construir volume mounts
$volumeMounts = @()
if ($currentConfig.properties.template.containers[0].volumeMounts) {
    foreach ($vm in $currentConfig.properties.template.containers[0].volumeMounts) {
        $volumeMounts += @{
            volumeName = $vm.volumeName
            mountPath = $vm.mountPath
        }
    }
}

# Adicionar volume mount se nao existir
$hasVolumeMount = $false
foreach ($vm in $volumeMounts) {
    if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
        $hasVolumeMount = $true
        break
    }
}

if (-not $hasVolumeMount) {
    $volumeMounts += @{
        volumeName = "documents-storage"
        mountPath = "/app/DOC-IA"
    }
}

# Construir objeto JSON completo
$updateConfig = @{
    properties = @{
        environmentId = $envId
        template = @{
            containers = @(
                @{
                    name = $currentConfig.properties.template.containers[0].name
                    image = $currentConfig.properties.template.containers[0].image
                    env = $envVars
                    resources = @{
                        cpu = $currentConfig.properties.template.containers[0].resources.cpu
                        memory = $currentConfig.properties.template.containers[0].resources.memory
                    }
                    volumeMounts = $volumeMounts
                }
            )
            scale = @{
                minReplicas = $currentConfig.properties.template.scale.minReplicas
                maxReplicas = $currentConfig.properties.template.scale.maxReplicas
            }
            volumes = $volumes
        }
    }
}

# Salvar JSON em arquivo temporario
$jsonFile = [System.IO.Path]::GetTempFileName() + ".json"
$updateConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding utf8

Write-Host "[INFO] JSON de atualizacao salvo em: $jsonFile" -ForegroundColor Gray
Write-Host "[INFO] Atualizando Container App..." -ForegroundColor Yellow

# Tentar atualizar usando --file (JSON)
$ErrorActionPreference = "Continue"
$updateOutput = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --file $jsonFile 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "[AVISO] --file falhou. Tentando com --yaml..." -ForegroundColor Yellow
    
    # Converter JSON para YAML manualmente
    $yamlFile = $jsonFile -replace "\.json$", ".yaml"
    
    # Construir YAML manualmente
    $yamlContent = "properties:`n"
    $yamlContent += "  environmentId: $envId`n"
    $yamlContent += "  template:`n"
    $yamlContent += "    containers:`n"
    $yamlContent += "    - name: $($currentConfig.properties.template.containers[0].name)`n"
    $yamlContent += "      image: $($currentConfig.properties.template.containers[0].image)`n"
    $yamlContent += "      env:`n"
    
    foreach ($env in $envVars) {
        $envValue = $env.value -replace '"', '\"'
        $yamlContent += "      - name: $($env.name)`n"
        $yamlContent += "        value: `"$envValue`"`n"
    }
    
    $yamlContent += "      resources:`n"
    $yamlContent += "        cpu: $($currentConfig.properties.template.containers[0].resources.cpu)`n"
    $yamlContent += "        memory: $($currentConfig.properties.template.containers[0].resources.memory)`n"
    $yamlContent += "      volumeMounts:`n"
    
    foreach ($vm in $volumeMounts) {
        $yamlContent += "      - volumeName: $($vm.volumeName)`n"
        $yamlContent += "        mountPath: $($vm.mountPath)`n"
    }
    
    $yamlContent += "    scale:`n"
    $yamlContent += "      minReplicas: $($currentConfig.properties.template.scale.minReplicas)`n"
    $yamlContent += "      maxReplicas: $($currentConfig.properties.template.scale.maxReplicas)`n"
    $yamlContent += "    volumes:`n"
    
    foreach ($vol in $volumes) {
        $yamlContent += "    - name: $($vol.name)`n"
        $yamlContent += "      storageType: $($vol.storageType)`n"
        $yamlContent += "      storageName: $($vol.storageName)`n"
    }
    
    $yamlContent | Out-File -FilePath $yamlFile -Encoding utf8 -NoNewline
    
    Write-Host "[INFO] YAML salvo em: $yamlFile" -ForegroundColor Gray
    
    $updateOutput = az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --yaml $yamlFile 2>&1
}

$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado!" -ForegroundColor Green
    
    # Verificar se o volume foi realmente adicionado
    Write-Host "[INFO] Verificando se o volume foi aplicado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    $verifyConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json | ConvertFrom-Json
    $volumeFound = $false
    
    if ($verifyConfig) {
        foreach ($vol in $verifyConfig) {
            if ($vol.name -eq "documents-storage") {
                $volumeFound = $true
                Write-Host "[OK] Volume 'documents-storage' confirmado no Container App!" -ForegroundColor Green
                break
            }
        }
    }
    
    if (-not $volumeFound) {
        Write-Host "[AVISO] Volume nao foi aplicado. Verifique o arquivo de configuracao:" -ForegroundColor Yellow
        Write-Host "  JSON: $jsonFile" -ForegroundColor Gray
        if (Test-Path $yamlFile) {
            Write-Host "  YAML: $yamlFile" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "[INFO] Tente adicionar o volume manualmente pelo portal Azure:" -ForegroundColor Cyan
        Write-Host "  1. Va para: https://portal.azure.com" -ForegroundColor Gray
        Write-Host "  2. Navegue ate: $ResourceGroup > $ApiAppName > Volumes" -ForegroundColor Gray
        Write-Host "  3. Clique em '+ Add'" -ForegroundColor Gray
        Write-Host "  4. Selecione 'documents-storage' do Environment" -ForegroundColor Gray
        Write-Host "  5. Mount path: /app/DOC-IA" -ForegroundColor Gray
    } else {
        # Limpar arquivos temporarios
        Remove-Item $jsonFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $yamlFile) {
            Remove-Item $yamlFile -Force -ErrorAction SilentlyContinue
        }
        
        Write-Host ""
        Write-Host "[OK] Volume configurado com sucesso!" -ForegroundColor Green
        Write-Host "[INFO] Forcando nova revision..." -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        Write-Host "[INFO] Aguarde alguns minutos e verifique: .\infra\check_volume_mount.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
    Write-Host "Erro: $updateOutput" -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Arquivos de configuracao mantidos para inspecao:" -ForegroundColor Yellow
    Write-Host "  JSON: $jsonFile" -ForegroundColor Gray
    if (Test-Path $yamlFile) {
        Write-Host "  YAML: $yamlFile" -ForegroundColor Gray
    }
    exit 1
}

Write-Host ""
