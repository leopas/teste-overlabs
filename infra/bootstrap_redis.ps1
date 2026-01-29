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

# Criar Redis Container App via YAML (contorna parsing do Azure CLI com --args)
Write-Host "[INFO] Criando Redis Container App via YAML..." -ForegroundColor Yellow

# Obter environment ID e location (sem capturar stderr)
$ErrorActionPreference = "Continue"
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv 2>$null
$location = az containerapp env show --name $Environment --resource-group $ResourceGroup --query location -o tsv 2>$null
$ErrorActionPreference = "Stop"

$envId = ("" + $envId).Trim()
$location = ("" + $location).Trim()
if (-not $location -or $location -match "error|not found") {
    $location = "brazilsouth"
}
$location = $location.ToLower().Replace(' ', '')

$yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
  configuration:
    ingress:
      external: false
      targetPort: 6379
      transport: Tcp
  template:
    containers:
    - name: redis
      image: redis:7-alpine
      command:
      - redis-server
      args:
      - --appendonly
      - "no"
      - --protected-mode
      - "no"
      - --bind
      - 0.0.0.0
      resources:
        cpu: 0.5
        memory: 1.0Gi
    scale:
      minReplicas: 1
      maxReplicas: 1
"@

$tempYaml = [System.IO.Path]::GetTempFileName() + ".yaml"
# Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tempYaml, $yamlContent, $utf8NoBom)

$ErrorActionPreference = "Continue"
try {
    $out = az containerapp create `
        --name $RedisApp `
        --resource-group $ResourceGroup `
        --yaml $tempYaml 2>&1
} finally {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[AVISO] YAML temporário mantido para debug: $tempYaml" -ForegroundColor Yellow
    } else {
        Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
    }
}
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Redis Container App criado (YAML)" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao criar Redis Container App via YAML" -ForegroundColor Red
    if ($out) {
        Write-Host $out
    }
    exit 1
}
