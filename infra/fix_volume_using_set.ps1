# Script para corrigir volume mount usando --set (patch direto)
# 
# Uso: .\infra\fix_volume_using_set.ps1 -ResourceGroup "rg-overlabs-prod" -ContainerApp "app-overlabs-prod-248"
#
# Este script implementa a alternativa robusta usando --set para patch direto,
# evitando problemas de merge de YAML.

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ContainerApp = "app-overlabs-prod-248",
    [string]$VolumeName = "docs",
    [string]$MountPath = "/app/DOC-IA",
    [string]$RevisionSuffix = "docsset"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Corrigir Volume Mount (Método --set) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ContainerApp" -ForegroundColor Yellow
Write-Host "[INFO] Volume Name: $VolumeName" -ForegroundColor Yellow
Write-Host "[INFO] Mount Path: $MountPath" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $ContainerApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Container App '$ContainerApp' não encontrado!" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"
Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# 2. Identificar container e índice
Write-Host "[INFO] Identificando container..." -ForegroundColor Yellow
$containers = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers" -o json | ConvertFrom-Json

if ($containers.Count -eq 0) {
    Write-Host "[ERRO] Nenhum container encontrado!" -ForegroundColor Red
    exit 1
}

# Encontrar índice do container (geralmente é 0, mas vamos verificar)
$containerIndex = 0
$containerName = $containers[0].name
Write-Host "[OK] Container encontrado: '$containerName' (índice: $containerIndex)" -ForegroundColor Green
Write-Host ""

# 3. Verificar se volume mount já existe
Write-Host "[INFO] Verificando volume mount atual..." -ForegroundColor Yellow
$currentMounts = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[$containerIndex].volumeMounts" -o json | ConvertFrom-Json

if ($currentMounts) {
    $existingMount = $currentMounts | Where-Object { $_.volumeName -eq $VolumeName -and $_.mountPath -eq $MountPath }
    if ($existingMount) {
        Write-Host "[OK] Volume mount já está configurado!" -ForegroundColor Green
        Write-Host "  - Volume: $($existingMount.volumeName)" -ForegroundColor Gray
        Write-Host "  - Mount Path: $($existingMount.mountPath)" -ForegroundColor Gray
        exit 0
    }
    
    # Se existem outros mounts, vamos adicionar ao array existente
    Write-Host "[INFO] Volume mounts existentes encontrados. Adicionando novo mount..." -ForegroundColor Yellow
    $mountsArray = @($currentMounts)
    $mountsArray += @{
        volumeName = $VolumeName
        mountPath = $MountPath
    }
} else {
    # Criar novo array com apenas este mount
    Write-Host "[INFO] Nenhum volume mount existente. Criando novo..." -ForegroundColor Yellow
    $mountsArray = @(@{
        volumeName = $VolumeName
        mountPath = $MountPath
    })
}

# 4. Converter para JSON string para --set
$mountsJson = $mountsArray | ConvertTo-Json -Compress
# Escapar aspas para PowerShell
$mountsJsonEscaped = $mountsJson -replace '"', '\"'

Write-Host "[INFO] Volume mounts a aplicar:" -ForegroundColor Cyan
$mountsArray | ConvertTo-Json | Write-Host
Write-Host ""

# 5. Gerar revision suffix único se não fornecido
if ($RevisionSuffix -eq "docsset") {
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $RevisionSuffix = "docsset$timestamp"
}

# 6. Aplicar usando --set
Write-Host "[INFO] Aplicando volume mount usando --set..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

try {
    # Usar --set para aplicar volumeMounts diretamente
    az containerapp update `
        --name $ContainerApp `
        --resource-group $ResourceGroup `
        --set "properties.template.containers[$containerIndex].volumeMounts=$mountsJsonEscaped" `
        --revision-suffix $RevisionSuffix 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Update aplicado com sucesso!" -ForegroundColor Green
        Write-Host "[OK] Nova revision: $ContainerApp--$RevisionSuffix" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao aplicar update!" -ForegroundColor Red
        Write-Host "[INFO] Tente executar manualmente:" -ForegroundColor Cyan
        Write-Host "  az containerapp update -g $ResourceGroup -n $ContainerApp --set `"properties.template.containers[$containerIndex].volumeMounts=$mountsJsonEscaped`" --revision-suffix $RevisionSuffix" -ForegroundColor Gray
        exit 1
    }
} catch {
    Write-Host "[ERRO] Falha ao aplicar update: $_" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
Write-Host ""

# 7. Validar resultado
Write-Host "[INFO] Validando volume mount..." -ForegroundColor Yellow
Start-Sleep -Seconds 5  # Aguardar propagação

$volumeMounts = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[$containerIndex].volumeMounts" -o json | ConvertFrom-Json

if ($volumeMounts -and $volumeMounts.Count -gt 0) {
    $mount = $volumeMounts | Where-Object { $_.volumeName -eq $VolumeName -and $_.mountPath -eq $MountPath }
    if ($mount) {
        Write-Host "[OK] Volume mount configurado corretamente!" -ForegroundColor Green
        Write-Host "  - Volume Name: $($mount.volumeName)" -ForegroundColor Gray
        Write-Host "  - Mount Path: $($mount.mountPath)" -ForegroundColor Gray
    } else {
        Write-Host "[AVISO] Volume mount existe mas não está como esperado" -ForegroundColor Yellow
        Write-Host "[INFO] Volume mounts encontrados:" -ForegroundColor Cyan
        $volumeMounts | ConvertTo-Json | Write-Host
    }
} else {
    Write-Host "[ERRO] Volume mount ainda não está configurado!" -ForegroundColor Red
    Write-Host "[INFO] Tente usar o método de export YAML: .\infra\fix_volume_export_and_update.ps1" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Verificar se o diretório está acessível:" -ForegroundColor Cyan
Write-Host "     az containerapp exec -g $ResourceGroup -n $ContainerApp --command 'ls -la $MountPath'" -ForegroundColor Gray
Write-Host "  2. Se necessário, executar ingestão de documentos" -ForegroundColor Cyan
