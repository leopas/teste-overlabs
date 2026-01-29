# Script para criar/verificar Redis Container App
# Uso: .\infra\bootstrap_redis.ps1 -ResourceGroup "rg-overlabs-prod" -Environment "env-overlabs-prod-300" -RedisApp "app-overlabs-redis-prod-300"

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [Parameter(Mandatory=$true)]
    [string]$RedisApp,

    # Se definido, deleta e recria o Container App do Redis
    [switch]$Recreate
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
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Redis Container App já existe" -ForegroundColor Green

    if ($Recreate) {
        Write-Host "[INFO] Recreate solicitado. Deletando Redis Container App..." -ForegroundColor Yellow
        az containerapp delete --name $RedisApp --resource-group $ResourceGroup --yes 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERRO] Falha ao deletar Redis Container App" -ForegroundColor Red
            exit 1
        }

        # Aguardar o recurso sumir (evita erro de conflito ao recriar)
        Write-Host "[INFO] Aguardando exclusão completar..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        for ($i = 0; $i -lt 30; $i++) {
            $null = az containerapp show --name $RedisApp --resource-group $ResourceGroup 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { break }
            Start-Sleep -Seconds 2
        }
        $ErrorActionPreference = "Stop"
        Write-Host "[OK] Redis Container App deletado" -ForegroundColor Green
    } else {
        # Sem recreate, apenas sair (não mexe no app existente)
        $ErrorActionPreference = "Stop"
        Write-Host ""
        exit 0
    }
}

$ErrorActionPreference = "Stop"
Write-Host ""

# Criar Redis Container App via CLI (contorna parsing do Azure CLI com valores iniciando em '-')
#
# Nota: algumas versões do Azure CLI/extension tratam valores como "-lc" como flags,
# então usamos a forma "--args=-lc" (com '=') e colocamos o resto do comando em uma string única.
Write-Host "[INFO] Criando Redis Container App..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$out = az containerapp create `
    --name $RedisApp `
    --resource-group $ResourceGroup `
    --environment $Environment `
    --image redis:7-alpine `
    --ingress internal `
    --target-port 6379 `
    --transport tcp `
    --cpu 0.5 `
    --memory 1.0Gi `
    --min-replicas 1 `
    --max-replicas 1 `
    --command "sh" `
    --args=-lc "exec redis-server --appendonly no --protected-mode no --bind 0.0.0.0" 2>&1
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Redis Container App criado" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao criar Redis Container App" -ForegroundColor Red
    if ($out) { Write-Host $out }
    exit 1
}
