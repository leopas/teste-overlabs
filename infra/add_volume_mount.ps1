# Script para adicionar volume mount quando o volume ja existe mas o mount nao esta configurado

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [string]$VolumeName = "docs",
    [string]$MountPath = "/app/DOC-IA"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionar Volume Mount ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Volume Name: $VolumeName" -ForegroundColor Yellow
Write-Host "[INFO] Mount Path: $MountPath" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar se o volume existe
Write-Host "[INFO] Verificando se o volume existe..." -ForegroundColor Yellow
$volumes = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json | ConvertFrom-Json

$volumeExists = $false
if ($volumes) {
    foreach ($vol in $volumes) {
        if ($vol.name -eq $VolumeName) {
            $volumeExists = $true
            Write-Host "[OK] Volume '$VolumeName' encontrado" -ForegroundColor Green
            break
        }
    }
}

if (-not $volumeExists) {
    Write-Host "[ERRO] Volume '$VolumeName' nao encontrado no Container App!" -ForegroundColor Red
    Write-Host "[INFO] Volumes disponiveis:" -ForegroundColor Yellow
    if ($volumes) {
        foreach ($vol in $volumes) {
            Write-Host "  - $($vol.name)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  Nenhum volume encontrado" -ForegroundColor Gray
    }
    exit 1
}
Write-Host ""

# 2. Verificar se o volume mount ja existe
Write-Host "[INFO] Verificando se o volume mount ja existe..." -ForegroundColor Yellow
$volumeMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json

$mountExists = $false
if ($volumeMounts) {
    foreach ($vm in $volumeMounts) {
        if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
            $mountExists = $true
            Write-Host "[OK] Volume mount ja existe" -ForegroundColor Green
            break
        }
    }
}

if ($mountExists) {
    Write-Host "[INFO] Nada a fazer. Volume mount ja esta configurado." -ForegroundColor Cyan
    exit 0
}
Write-Host ""

# 3. Obter configuracao atual
Write-Host "[INFO] Obtendo configuracao atual do Container App..." -ForegroundColor Yellow
$currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json | ConvertFrom-Json
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv

# 4. Construir volume mounts (adicionar o novo)
$newVolumeMounts = @()
if ($currentConfig.properties.template.containers[0].volumeMounts) {
    foreach ($vm in $currentConfig.properties.template.containers[0].volumeMounts) {
        $newVolumeMounts += @{
            volumeName = $vm.volumeName
            mountPath = $vm.mountPath
        }
    }
}

# Adicionar o novo volume mount
$newVolumeMounts += @{
    volumeName = $VolumeName
    mountPath = $MountPath
}

# 5. Construir YAML para atualizacao
$envVarsYaml = ""
if ($currentConfig.properties.template.containers[0].env) {
    foreach ($env in $currentConfig.properties.template.containers[0].env) {
        $envValue = $env.value
        # Escapar Key Vault references corretamente
        if ($envValue -match '^@Microsoft\.KeyVault') {
            $envValueEscaped = $envValue -replace '"', '\"'
            $envVarsYaml += "      - name: $($env.name)`n        value: `"$envValueEscaped`"`n"
        } else {
            $envValue = $envValue -replace '\\', '\\\\'  # Escapar backslashes primeiro
            $envValue = $envValue -replace '"', '\"'      # Escapar aspas
            $envVarsYaml += "      - name: $($env.name)`n        value: `"$envValue`"`n"
        }
    }
}

$volumeMountsYaml = ""
foreach ($vm in $newVolumeMounts) {
    $volumeMountsYaml += "      - volumeName: $($vm.volumeName)`n        mountPath: $($vm.mountPath)`n"
}

$volumesYaml = ""
foreach ($vol in $volumes) {
    $volumesYaml += "    - name: $($vol.name)`n      storageType: $($vol.storageType)`n      storageName: $($vol.storageName)`n"
}

$yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
  template:
    containers:
    - name: $($currentConfig.properties.template.containers[0].name)
      image: $($currentConfig.properties.template.containers[0].image)
      env:
$envVarsYaml
      resources:
        cpu: $($currentConfig.properties.template.containers[0].resources.cpu)
        memory: $($currentConfig.properties.template.containers[0].resources.memory)
      volumeMounts:
$volumeMountsYaml    scale:
      minReplicas: $($currentConfig.properties.template.scale.minReplicas)
      maxReplicas: $($currentConfig.properties.template.scale.maxReplicas)
    volumes:
$volumesYaml
"@

$yamlFile = [System.IO.Path]::GetTempFileName() + ".yaml"
# Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($yamlFile, $yamlContent, $utf8NoBom)

Write-Host "[INFO] Atualizando Container App com volume mount..." -ForegroundColor Yellow
Write-Host "[DEBUG] YAML salvo em: $yamlFile" -ForegroundColor Gray

$ErrorActionPreference = "Continue"
$updateOutput = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --yaml $yamlFile 2>&1
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado com volume mount!" -ForegroundColor Green
    
    # Verificar se foi aplicado
    Start-Sleep -Seconds 5
    $verifyMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json
    
    $mountFound = $false
    if ($verifyMounts) {
        foreach ($vm in $verifyMounts) {
            if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
                $mountFound = $true
                break
            }
        }
    }
    
    if ($mountFound) {
        Write-Host "[OK] Volume mount confirmado!" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Volume mount nao foi confirmado. Aguardando mais tempo..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        
        # Verificar novamente
        $verifyMounts2 = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json
        
        $mountFound = $false
        if ($verifyMounts2) {
            foreach ($vm in $verifyMounts2) {
                if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
                    $mountFound = $true
                    Write-Host "[OK] Volume mount confirmado na segunda verificacao!" -ForegroundColor Green
                    break
                }
            }
        }
        
        if (-not $mountFound) {
            Write-Host "[AVISO] Volume mount ainda nao foi aplicado." -ForegroundColor Yellow
            Write-Host "[INFO] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Gray
            Write-Host "[INFO] Tente adicionar manualmente pelo portal Azure:" -ForegroundColor Cyan
            Write-Host "  1. Va para: https://portal.azure.com" -ForegroundColor Gray
            Write-Host "  2. Navegue ate: $ResourceGroup > $ApiAppName > Containers" -ForegroundColor Gray
            Write-Host "  3. Edite o container e adicione Volume Mount:" -ForegroundColor Gray
            Write-Host "     - Volume: $VolumeName" -ForegroundColor Gray
            Write-Host "     - Mount Path: $MountPath" -ForegroundColor Gray
            exit 1
        }
    }
    
    Write-Host "[INFO] Forcando nova revision para aplicar volume mount..." -ForegroundColor Yellow
    
    $ErrorActionPreference = "Continue"
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    
    Write-Host "[OK] Nova revision sera criada" -ForegroundColor Green
    Write-Host "[INFO] Aguarde 60-90 segundos e verifique: .\infra\verify_volume_working.ps1" -ForegroundColor Cyan
    
    Remove-Item $yamlFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
    Write-Host "Erro: $updateOutput" -ForegroundColor Red
    Write-Host "[INFO] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
