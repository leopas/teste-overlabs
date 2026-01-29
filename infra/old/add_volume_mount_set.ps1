# Script para adicionar volume mount usando --set (patch direto)
# Metodo alternativo quando YAML nao funciona

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$VolumeName = "docs",
    [string]$MountPath = "/app/DOC-IA"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionar Volume Mount (Metodo --set) ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se nao fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
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
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Volume Name: $VolumeName" -ForegroundColor Yellow
Write-Host "[INFO] Mount Path: $MountPath" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar nome real do container e obter volumeMounts existentes
Write-Host "[INFO] Obtendo configuracao atual..." -ForegroundColor Yellow
$containerConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json
$containerName = $containerConfig.name

Write-Host "[OK] Container: $containerName" -ForegroundColor Green

# Obter volumeMounts existentes
$existingMounts = @()
if ($containerConfig.volumeMounts) {
    foreach ($vm in $containerConfig.volumeMounts) {
        $existingMounts += @{
            volumeName = $vm.volumeName
            mountPath = $vm.mountPath
        }
    }
}

# Verificar se ja existe
$mountExists = $false
foreach ($vm in $existingMounts) {
    if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
        $mountExists = $true
        Write-Host "[OK] Volume mount ja existe!" -ForegroundColor Green
        exit 0
    }
}

# Adicionar novo mount
$existingMounts += @{
    volumeName = $VolumeName
    mountPath = $MountPath
}

# Converter para JSON
$mountsJson = $existingMounts | ConvertTo-Json -Compress

Write-Host "[INFO] Aplicando volume mount usando --set..." -ForegroundColor Yellow
Write-Host "[DEBUG] Mounts JSON: $mountsJson" -ForegroundColor Gray

# 2. Aplicar usando --set
$ErrorActionPreference = "Continue"
$updateOutput = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set "properties.template.containers[0].volumeMounts=$mountsJson" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Volume mount aplicado!" -ForegroundColor Green
    
    # Verificar se foi aplicado
    Write-Host "[INFO] Verificando se volume mount foi aplicado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    $verifyMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json
    
    $mountFound = $false
    if ($verifyMounts) {
        foreach ($vm in $verifyMounts) {
            if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
                $mountFound = $true
                Write-Host "[OK] Volume mount confirmado!" -ForegroundColor Green
                Write-Host "  - Volume: $($vm.volumeName)" -ForegroundColor Gray
                Write-Host "  - Mount Path: $($vm.mountPath)" -ForegroundColor Gray
                break
            }
        }
    }
    
    if ($mountFound) {
        Write-Host ""
        Write-Host "[OK] Volume mount adicionado com sucesso!" -ForegroundColor Green
        Write-Host "[INFO] Forcando nova revision..." -ForegroundColor Yellow
        
        az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
        
        Write-Host "[INFO] Aguarde alguns minutos e verifique: .\infra\verify_volume_working.ps1" -ForegroundColor Cyan
    } else {
        Write-Host "[AVISO] Volume mount nao foi confirmado." -ForegroundColor Yellow
        Write-Host "[INFO] Tente o metodo de exportar YAML: .\infra\add_volume_mount_export_yaml.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host "[ERRO] Falha ao aplicar volume mount" -ForegroundColor Red
    Write-Host "Erro: $updateOutput" -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Tente o metodo de exportar YAML: .\infra\add_volume_mount_export_yaml.ps1" -ForegroundColor Cyan
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
