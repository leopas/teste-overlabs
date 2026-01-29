# Script para adicionar volume mount usando o metodo mais confiavel:
# 1. Exporta YAML completo do Container App
# 2. Edita adicionando volume mount
# 3. Reaplica o YAML completo

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$VolumeName = "docs",
    [string]$MountPath = "/app/DOC-IA"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionar Volume Mount (Metodo Confiavel) ===" -ForegroundColor Cyan
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

# 1. Verificar nome real do container
Write-Host "[INFO] Verificando nome real do container..." -ForegroundColor Yellow
$containerNames = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[].name" -o tsv

if (-not $containerNames) {
    Write-Host "[ERRO] Nao foi possivel obter containers do Container App." -ForegroundColor Red
    exit 1
}

$containerName = ($containerNames | Select-Object -First 1)
Write-Host "[OK] Container encontrado: $containerName" -ForegroundColor Green
Write-Host ""

# 2. Verificar se volume mount ja existe
Write-Host "[INFO] Verificando se volume mount ja existe..." -ForegroundColor Yellow
$existingMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[?name=='$containerName'].volumeMounts" -o json | ConvertFrom-Json

$mountExists = $false
if ($existingMounts) {
    foreach ($vm in $existingMounts) {
        if ($vm.volumeName -eq $VolumeName -and $vm.mountPath -eq $MountPath) {
            $mountExists = $true
            Write-Host "[OK] Volume mount ja existe!" -ForegroundColor Green
            exit 0
        }
    }
}

if (-not $mountExists) {
    Write-Host "[INFO] Volume mount nao existe. Adicionando..." -ForegroundColor Yellow
}
Write-Host ""

# 3. Verificar se volume existe
Write-Host "[INFO] Verificando se volume existe..." -ForegroundColor Yellow
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
    Write-Host "[INFO] Adicione o volume primeiro pelo portal ou execute: .\infra\mount_docs_volume.ps1" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 4. Exportar YAML completo do Container App
Write-Host "[INFO] Exportando YAML completo do Container App..." -ForegroundColor Yellow
$yamlFile = "app_export_$(Get-Date -Format 'yyyyMMddHHmmss').yaml"
az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o yaml | Out-File -FilePath $yamlFile -Encoding utf8

if (-not (Test-Path $yamlFile)) {
    Write-Host "[ERRO] Falha ao exportar YAML." -ForegroundColor Red
    exit 1
}

Write-Host "[OK] YAML exportado para: $yamlFile" -ForegroundColor Green
Write-Host ""

# 5. Ler e editar YAML
Write-Host "[INFO] Editando YAML para adicionar volume mount..." -ForegroundColor Yellow
$yamlContent = Get-Content $yamlFile -Raw

# Verificar se volumeMounts ja existe no container
if ($yamlContent -match "containers:\s*\n\s*- name:\s*$containerName" -and $yamlContent -notmatch "volumeMounts:") {
    # Adicionar volumeMounts apos resources do container
    $pattern = "(containers:\s*\n\s*- name:\s*$containerName[^\n]*\n(?:[^\n]*\n)*?\s+resources:[^\n]*\n(?:[^\n]*\n)*?)"
    $replacement = "`$1      volumeMounts:`n      - volumeName: $VolumeName`n        mountPath: $MountPath`n"
    $yamlContent = $yamlContent -replace $pattern, $replacement
} elseif ($yamlContent -match "containers:\s*\n\s*- name:\s*$containerName") {
    # Se nao encontrou resources, adicionar apos env ou name
    $pattern = "(containers:\s*\n\s*- name:\s*$containerName[^\n]*\n(?:[^\n]*\n)*?)(\s+env:|\s+resources:)"
    $replacement = "`$1      volumeMounts:`n      - volumeName: $VolumeName`n        mountPath: $MountPath`n`$2"
    $yamlContent = $yamlContent -replace $pattern, $replacement
} else {
    Write-Host "[AVISO] Nao foi possivel encontrar o container '$containerName' no YAML para adicionar volumeMounts automaticamente." -ForegroundColor Yellow
    Write-Host "[INFO] Edite manualmente o arquivo: $yamlFile" -ForegroundColor Cyan
    Write-Host "[INFO] Adicione o seguinte no container '$containerName':" -ForegroundColor Cyan
    Write-Host "      volumeMounts:" -ForegroundColor Gray
    Write-Host "      - volumeName: $VolumeName" -ForegroundColor Gray
    Write-Host "        mountPath: $MountPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Depois execute: az containerapp update -n $ApiAppName -g $ResourceGroup --yaml $yamlFile --debug" -ForegroundColor Cyan
    exit 1
}

# Salvar YAML editado
$yamlFileEdited = $yamlFile -replace '\.yaml$', '_edited.yaml'
$yamlContent | Out-File -FilePath $yamlFileEdited -Encoding utf8 -NoNewline

Write-Host "[OK] YAML editado salvo em: $yamlFileEdited" -ForegroundColor Green
Write-Host ""

# 6. Aplicar YAML editado
Write-Host "[INFO] Aplicando YAML editado..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$updateOutput = az containerapp update --name $ApiAppName --resource-group $ResourceGroup --yaml $yamlFileEdited --debug 2>&1
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] YAML aplicado com sucesso!" -ForegroundColor Green
    
    # Verificar se foi aplicado
    Write-Host "[INFO] Verificando se volume mount foi aplicado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    $verifyMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[?name=='$containerName'].volumeMounts" -o json | ConvertFrom-Json
    
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
        # Limpar arquivos temporarios
        Remove-Item $yamlFile -Force -ErrorAction SilentlyContinue
        Remove-Item $yamlFileEdited -Force -ErrorAction SilentlyContinue
        
        Write-Host ""
        Write-Host "[OK] Volume mount adicionado com sucesso!" -ForegroundColor Green
        Write-Host "[INFO] Forcando nova revision..." -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        Write-Host "[INFO] Aguarde alguns minutos e verifique: .\infra\verify_volume_working.ps1" -ForegroundColor Cyan
    } else {
        Write-Host "[AVISO] Volume mount nao foi confirmado." -ForegroundColor Yellow
        Write-Host "[INFO] Arquivos YAML mantidos para inspecao:" -ForegroundColor Yellow
        Write-Host "  - Original: $yamlFile" -ForegroundColor Gray
        Write-Host "  - Editado: $yamlFileEdited" -ForegroundColor Gray
        Write-Host ""
        Write-Host "[INFO] Tente usar --set como alternativa:" -ForegroundColor Cyan
        Write-Host "  az containerapp update -n $ApiAppName -g $ResourceGroup --set properties.template.containers[0].volumeMounts='[{\"volumeName\":\"$VolumeName\",\"mountPath\":\"$MountPath\"}]'" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Falha ao aplicar YAML" -ForegroundColor Red
    Write-Host "Erro: $updateOutput" -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Arquivos YAML mantidos para inspecao:" -ForegroundColor Yellow
    Write-Host "  - Original: $yamlFile" -ForegroundColor Gray
    Write-Host "  - Editado: $yamlFileEdited" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[INFO] Tente aplicar manualmente: az containerapp update -n $ApiAppName -g $ResourceGroup --yaml $yamlFileEdited --debug" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
