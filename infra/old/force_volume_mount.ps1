# Script para forçar aplicação do volume mount reiniciando a revision

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Forçar Aplicação do Volume Mount ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
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
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# Obter revision mais recente
Write-Host "[INFO] Obtendo revision mais recente..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$latestRevision = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.latestRevisionName" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $latestRevision) {
    Write-Host "[ERRO] Não foi possível obter revision" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Latest Revision: $latestRevision" -ForegroundColor Green
Write-Host ""

# Verificar se volume mount está configurado
Write-Host "[INFO] Verificando volume mount..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeMounts = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

$hasMount = $false
if ($volumeMounts) {
    foreach ($vm in $volumeMounts) {
        if ($vm.volumeName -eq "docs" -and $vm.mountPath -eq "/app/DOC-IA") {
            $hasMount = $true
            Write-Host "[OK] Volume mount encontrado na revision" -ForegroundColor Green
            break
        }
    }
}

if (-not $hasMount) {
    Write-Host "[ERRO] Volume mount não encontrado na revision!" -ForegroundColor Red
    Write-Host "[INFO] Execute primeiro: .\infra\add_volume_mount.ps1" -ForegroundColor Yellow
    exit 1
}

# Forçar nova revision atualizando uma variável de ambiente dummy
Write-Host "[INFO] Forçando nova revision para aplicar volume mount..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$trigger = "VOLUME_MOUNT_FORCE_$(Get-Date -Format 'yyyyMMddHHmmss')"
az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "$trigger=1" 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Nova revision criada" -ForegroundColor Green
    
    # Aguardar um pouco e verificar nova revision
    Write-Host "[INFO] Aguardando 10 segundos..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    $newRevision = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.latestRevisionName" -o tsv 2>$null
    Write-Host "[INFO] Nova revision: $newRevision" -ForegroundColor Cyan
    
    # Reiniciar a revision para garantir que o volume seja montado
    Write-Host "[INFO] Reiniciando revision para aplicar volume mount..." -ForegroundColor Yellow
    az containerapp revision restart `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --revision $newRevision 2>&1 | Out-Null
    
    Write-Host "[OK] Revision reiniciada" -ForegroundColor Green
    Write-Host "[INFO] Aguarde 30-60 segundos e verifique:" -ForegroundColor Cyan
    Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Falha ao criar nova revision" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
Write-Host ""
