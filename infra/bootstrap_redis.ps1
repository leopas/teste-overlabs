# Script para criar/verificar Redis Container App
# Uso: .\infra\bootstrap_redis.ps1 -ResourceGroup "rg-overlabs-prod" -Environment "env-overlabs-prod-300" -RedisApp "app-overlabs-redis-prod-300"

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [Parameter(Mandatory=$true)]
    [string]$RedisApp
)

$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap Redis Container App ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] Redis Container App: $RedisApp" -ForegroundColor Yellow
Write-Host ""

# Verificar se já existe
Write-Host "[INFO] Verificando Redis Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $RedisApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Redis Container App..." -ForegroundColor Yellow
    az containerapp create `
        --name $RedisApp `
        --resource-group $ResourceGroup `
        --environment $Environment `
        --image redis:7-alpine `
        --target-port 6379 `
        --ingress internal `
        --command "redis-server" `
        --cpu 0.5 `
        --memory 1.0Gi `
        --min-replicas 1 `
        --max-replicas 1 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Redis Container App criado" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao criar Redis Container App" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Redis Container App já existe" -ForegroundColor Green
}

$ErrorActionPreference = "Stop"
Write-Host ""

# Garantir que o Redis aceite conexões internas (evita protected-mode/bind localhost)
Write-Host "[INFO] Garantindo command/args corretos do Redis..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az containerapp update `
    --name $RedisApp `
    --resource-group $ResourceGroup `
    --set 'properties.template.containers[0].command=["redis-server"]' `
    --set 'properties.template.containers[0].args=["--appendonly","no","--protected-mode","no","--bind","0.0.0.0"]' 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Redis atualizado (command/args aplicados)" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Não foi possível atualizar command/args do Redis automaticamente. Verifique permissões/estado do app." -ForegroundColor Yellow
}
