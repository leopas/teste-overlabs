# Script para verificar se os YAMLs locais e o bootstrap têm a montagem do storage configurada

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar Configuração de Volume nos YAMLs ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar docker-compose.yml (desenvolvimento local)
Write-Host "[INFO] Verificando docker-compose.yml (desenvolvimento local)..." -ForegroundColor Yellow
$dockerCompose = Get-Content "docker-compose.yml" -Raw -ErrorAction SilentlyContinue

if ($dockerCompose) {
    if ($dockerCompose -match "DOC-IA|DOCS_HOST_PATH") {
        Write-Host "[OK] docker-compose.yml tem configuração de documentos" -ForegroundColor Green
        if ($dockerCompose -match "DOCS_HOST_PATH.*:/docs") {
            Write-Host "  Volume montado: \${DOCS_HOST_PATH:-./DOC-IA}:/docs:ro" -ForegroundColor Gray
        }
    } else {
        Write-Host "[AVISO] docker-compose.yml não tem configuração de documentos" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] docker-compose.yml não encontrado" -ForegroundColor Yellow
}
Write-Host ""

# 2. Verificar bootstrap_container_apps.ps1 (Azure Container Apps)
Write-Host "[INFO] Verificando bootstrap_container_apps.ps1 (Azure Container Apps)..." -ForegroundColor Yellow
$bootstrapScript = Get-Content "infra/bootstrap_container_apps.ps1" -Raw -ErrorAction SilentlyContinue

if ($bootstrapScript) {
    $hasVolumeMount = $bootstrapScript -match "volumeMounts" -and $bootstrapScript -match "documents-storage" -and $bootstrapScript -match "/app/DOC-IA"
    $hasVolumes = $bootstrapScript -match "volumes:" -and $bootstrapScript -match "documents-storage" -and $bootstrapScript -match "AzureFile"
    $hasStorageConfig = $bootstrapScript -match "documents-storage" -and $bootstrapScript -match "containerapp env storage"
    
    if ($hasVolumeMount -and $hasVolumes -and $hasStorageConfig) {
        Write-Host "[OK] bootstrap_container_apps.ps1 tem configuração completa de volume" -ForegroundColor Green
        Write-Host "  Volume mount: documents-storage -> /app/DOC-IA" -ForegroundColor Gray
        Write-Host "  Volume type: AzureFile" -ForegroundColor Gray
        Write-Host "  Storage config: documents-storage no Environment" -ForegroundColor Gray
    } else {
        Write-Host "[AVISO] bootstrap_container_apps.ps1 pode não ter configuração completa" -ForegroundColor Yellow
        if (-not $hasVolumeMount) {
            Write-Host "  ✗ Volume mount não encontrado" -ForegroundColor Red
        }
        if (-not $hasVolumes) {
            Write-Host "  ✗ Volumes não encontrado" -ForegroundColor Red
        }
        if (-not $hasStorageConfig) {
            Write-Host "  ✗ Storage config não encontrado" -ForegroundColor Red
        }
    }
} else {
    Write-Host "[AVISO] bootstrap_container_apps.ps1 não encontrado" -ForegroundColor Yellow
}
Write-Host ""

# 3. Verificar estado atual do Container App (se fornecido)
if ($ResourceGroup -and $ApiAppName) {
    Write-Host "[INFO] Verificando estado atual do Container App..." -ForegroundColor Yellow
    
    # Carregar deploy_state.json se não fornecido
    if (-not $ResourceGroup -or -not $ApiAppName) {
        $stateFile = ".azure/deploy_state.json"
        if (Test-Path $stateFile) {
            $state = Get-Content $stateFile | ConvertFrom-Json
            if (-not $ResourceGroup) {
                $ResourceGroup = $state.resourceGroup
            }
            if (-not $ApiAppName) {
                $ApiAppName = $state.apiAppName
            }
        }
    }
    
    if ($ResourceGroup -and $ApiAppName) {
        $ErrorActionPreference = "Continue"
        $appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template" -o json 2>$null | ConvertFrom-Json
        $ErrorActionPreference = "Stop"
        
        if ($appConfig) {
            # Verificar volumes
            $hasVolume = $false
            if ($appConfig.volumes) {
                foreach ($vol in $appConfig.volumes) {
                    if ($vol.name -eq "documents-storage") {
                        $hasVolume = $true
                        Write-Host "[OK] Container App tem volume 'documents-storage' definido" -ForegroundColor Green
                        Write-Host "  Tipo: $($vol.storageType)" -ForegroundColor Gray
                        Write-Host "  Storage Name: $($vol.storageName)" -ForegroundColor Gray
                        break
                    }
                }
            }
            
            if (-not $hasVolume) {
                Write-Host "[ERRO] Container App NÃO tem volume 'documents-storage' definido!" -ForegroundColor Red
            }
            
            # Verificar volume mounts
            $hasVolumeMount = $false
            if ($appConfig.containers[0].volumeMounts) {
                foreach ($vm in $appConfig.containers[0].volumeMounts) {
                    if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
                        $hasVolumeMount = $true
                        Write-Host "[OK] Container App tem volume mount configurado" -ForegroundColor Green
                        Write-Host "  Volume: $($vm.volumeName)" -ForegroundColor Gray
                        Write-Host "  Mount Path: $($vm.mountPath)" -ForegroundColor Gray
                        break
                    }
                }
            }
            
            if (-not $hasVolumeMount) {
                Write-Host "[ERRO] Container App NÃO tem volume mount configurado!" -ForegroundColor Red
            }
        } else {
            Write-Host "[AVISO] Não foi possível obter configuração do Container App" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[INFO] Para verificar estado do Container App, forneça -ResourceGroup e -ApiAppName" -ForegroundColor Gray
    Write-Host "  Ou execute: .\infra\check_volume_mount.ps1" -ForegroundColor Gray
}
Write-Host ""

Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuração nos arquivos:" -ForegroundColor Yellow
Write-Host "  docker-compose.yml (local): $(if ($dockerCompose -match 'DOC-IA|DOCS_HOST_PATH') { '✓' } else { '✗' })" -ForegroundColor $(if ($dockerCompose -match 'DOC-IA|DOCS_HOST_PATH') { 'Green' } else { 'Red' })
Write-Host "  bootstrap_container_apps.ps1: $(if ($hasVolumeMount -and $hasVolumes -and $hasStorageConfig) { '✓' } else { '✗' })" -ForegroundColor $(if ($hasVolumeMount -and $hasVolumes -and $hasStorageConfig) { 'Green' } else { 'Red' })
Write-Host ""
Write-Host "[INFO] Se o bootstrap tem a configuração mas o Container App não, execute:" -ForegroundColor Cyan
Write-Host "  .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
Write-Host ""
