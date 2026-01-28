# Script para parar todos os containers do projeto
# Uso: .\infra\stop_all.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== Parar Containers do Projeto ===" -ForegroundColor Cyan
Write-Host ""

# Verificar se Docker está rodando
$dockerRunning = docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Docker não está rodando. Inicie o Docker Desktop." -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Parando containers do docker-compose.yml..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
docker compose down 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Containers do docker-compose.yml parados" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Nenhum container do docker-compose.yml rodando" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[INFO] Verificando outros compose files..." -ForegroundColor Yellow

# Parar docker-compose.test.yml se existir
if (Test-Path "docker-compose.test.yml") {
    docker compose -f docker-compose.test.yml down 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Containers do docker-compose.test.yml parados" -ForegroundColor Green
    }
}

# Parar docker-compose.deploy.yml se existir
if (Test-Path "docker-compose.deploy.yml") {
    docker compose -f docker-compose.deploy.yml down 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Containers do docker-compose.deploy.yml parados" -ForegroundColor Green
    }
}

# Parar docker-compose.azure.yml se existir
if (Test-Path "docker-compose.azure.yml") {
    docker compose -f docker-compose.azure.yml down 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Containers do docker-compose.azure.yml parados" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "[INFO] Verificando containers órfãos do projeto..." -ForegroundColor Yellow

# Listar containers rodando que podem ser do projeto
$containers = docker ps --format "{{.Names}}" 2>&1 | Where-Object { $_ -match "teste-overlabs|choperia|qdrant|redis" }
if ($containers) {
    Write-Host "[INFO] Encontrados containers adicionais:" -ForegroundColor Yellow
    $containers | ForEach-Object {
        Write-Host "  - $_" -ForegroundColor Gray
        docker stop $_ 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [OK] Parado" -ForegroundColor Green
        }
    }
} else {
    Write-Host "[OK] Nenhum container órfão encontrado" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Todos os containers parados! ===" -ForegroundColor Green
Write-Host ""

# Mostrar status final
Write-Host "[INFO] Containers ainda rodando:" -ForegroundColor Cyan
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | Out-String
