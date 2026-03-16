# Controla "parar/iniciar" Container Apps via scale (min/max replicas).
# No ACA não existe "stop" direto do container; o equivalente é escalar para 0.
#
# Uso (recomendado, usando deploy_state.json):
#   .\infra\control_container_apps.ps1 -Action stop
#   .\infra\control_container_apps.ps1 -Action start
#
# Uso (manual):
#   .\infra\control_container_apps.ps1 -Action stop -ResourceGroup rg-overlabs-prod -ApiAppName app-overlabs-prod-300 -QdrantAppName app-overlabs-qdrant-prod-300 -RedisAppName app-overlabs-redis-prod-300

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("stop", "start")]
    [string]$Action,

    [string]$ResourceGroup,
    [string]$ApiAppName,
    [string]$QdrantAppName,
    [string]$RedisAppName,

    # Defaults para "start"
    [int]$ApiMin = 1,
    [int]$ApiMax = 5,
    [int]$QdrantMin = 1,
    [int]$QdrantMax = 1,
    [int]$RedisMin = 1,
    [int]$RedisMax = 1
)

$ErrorActionPreference = "Stop"

function Require($name, $val) {
    if (-not $val) { throw "Parâmetro obrigatório ausente: $name" }
}

function Invoke-AppScale($rg, $name, $min, $max) {
    Write-Host ("[INFO] {0}: min={1} max={2}" -f $name, $min, $max) -ForegroundColor Yellow
    az containerapp update -g $rg -n $name --min-replicas $min --max-replicas $max | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha ao atualizar scale do app: $name" }
}

# Tentar auto-carregar deploy_state.json se algum parâmetro estiver faltando
$statePath = Join-Path $PSScriptRoot "..\.azure\deploy_state.json"
if ((-not $ResourceGroup -or -not $ApiAppName -or -not $QdrantAppName -or -not $RedisAppName) -and (Test-Path $statePath)) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        if (-not $ResourceGroup) { $ResourceGroup = $state.resourceGroup }
        if (-not $ApiAppName) { $ApiAppName = $state.apiAppName }
        if (-not $QdrantAppName) { $QdrantAppName = $state.qdrantAppName }
        if (-not $RedisAppName) { $RedisAppName = $state.redisAppName }
    } catch {
        Write-Host "[AVISO] Não foi possível ler .azure/deploy_state.json. Forneça os parâmetros manualmente." -ForegroundColor Yellow
    }
}

Require "ResourceGroup" $ResourceGroup
Require "ApiAppName" $ApiAppName
Require "QdrantAppName" $QdrantAppName
Require "RedisAppName" $RedisAppName

Write-Host "=== Controlar Container Apps (ACA) ===" -ForegroundColor Cyan
Write-Host "[INFO] Action: $Action" -ForegroundColor Cyan
Write-Host "[INFO] ResourceGroup: $ResourceGroup" -ForegroundColor Cyan
Write-Host "[INFO] API: $ApiAppName" -ForegroundColor Cyan
Write-Host "[INFO] Qdrant: $QdrantAppName" -ForegroundColor Cyan
Write-Host "[INFO] Redis: $RedisAppName" -ForegroundColor Cyan
Write-Host ""

if ($Action -eq "stop") {
    Invoke-AppScale $ResourceGroup $ApiAppName 0 0
    Invoke-AppScale $ResourceGroup $QdrantAppName 0 0
    Invoke-AppScale $ResourceGroup $RedisAppName 0 0
    Write-Host "[OK] Apps escalados para 0 (parados)." -ForegroundColor Green
    exit 0
}

# start
Invoke-AppScale $ResourceGroup $ApiAppName $ApiMin $ApiMax
Invoke-AppScale $ResourceGroup $QdrantAppName $QdrantMin $QdrantMax
Invoke-AppScale $ResourceGroup $RedisAppName $RedisMin $RedisMax
Write-Host "[OK] Apps escalados para o padrão (iniciados)." -ForegroundColor Green

