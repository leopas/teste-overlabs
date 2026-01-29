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

function Invoke-Az {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Args
    )
    $ErrorActionPreference = "Continue"
    $out = & az @Args 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($code -ne 0) {
        throw ($out | Out-String)
    }
    return $out
}

# Criar Redis Container App com configurações mínimas (sem depender de --command/--args)
Write-Host "[INFO] Criando Redis Container App (base)..." -ForegroundColor Yellow
try {
    Invoke-Az -Args @(
        "containerapp","create",
        "--name",$RedisApp,
        "--resource-group",$ResourceGroup,
        "--environment",$Environment,
        "--image","redis:7-alpine",
        "--ingress","internal",
        "--target-port","6379",
        "--transport","tcp",
        "--cpu","0.5",
        "--memory","1.0Gi",
        "--min-replicas","1",
        "--max-replicas","1"
    ) | Out-Null
    Write-Host "[OK] Redis Container App criado (base)" -ForegroundColor Green
} catch {
    Write-Host "[ERRO] Falha ao criar Redis Container App (base)" -ForegroundColor Red
    Write-Host $_
    exit 1
}

# Aplicar command/args via ARM (az rest) para evitar bugs de parsing do PowerShell/Azure CLI
Write-Host "[INFO] Aplicando command/args do Redis via az rest..." -ForegroundColor Yellow
try {
    $sub = (Invoke-Az -Args @("account","show","--query","id","-o","tsv")).Trim()
    $apiVersion = "2026-01-01"
    # IMPORTANTE: em strings com interpolação, "$RedisApp?api-version=..." pode ser interpretado
    # como uma variável "RedisApp?api" inexistente, removendo o nome do app da URL.
    # Por isso montamos o base e concatenamos o querystring separadamente.
    $baseUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$RedisApp"
    $url = "${baseUrl}?api-version=$apiVersion"

    $appObj = (Invoke-Az -Args @("rest","--method","get","--url",$url)) | ConvertFrom-Json
    if (-not $appObj.properties -or -not $appObj.properties.template -or -not $appObj.properties.template.containers -or $appObj.properties.template.containers.Count -lt 1) {
        throw "Resposta do az rest GET não contém properties.template.containers[0]."
    }

    # IMPORTANTE: não podemos mandar um container "parcial" (sem image), senão o ARM rejeita.
    # Então pegamos o container atual e só alteramos command/args, preservando image/resources/env/etc.
    $container = $appObj.properties.template.containers[0]
    # Em algumas respostas, 'command'/'args' não existem como propriedades no PSCustomObject.
    # Usamos Add-Member para criar/atualizar de forma segura.
    $container | Add-Member -NotePropertyName "command" -NotePropertyValue @("redis-server") -Force
    $container | Add-Member -NotePropertyName "args" -NotePropertyValue @("--appendonly","no","--protected-mode","no","--bind","0.0.0.0") -Force

    $patch = @{
        properties = @{
            template = @{
                containers = @($container)
            }
        }
    }

    $tmpJson = Join-Path $env:TEMP "aca-redis-template-patch.json"
    $patch | ConvertTo-Json -Depth 20 | Out-File -Encoding utf8 $tmpJson

    # PATCH costuma funcionar; se seu tenant exigir PUT, troque method para put.
    Invoke-Az -Args @(
        "rest",
        "--method","patch",
        "--url",$url,
        "--headers","Content-Type=application/json",
        "--body","@$tmpJson"
    ) | Out-Null

    Write-Host "[OK] command/args aplicados (nova revision deve ser criada)" -ForegroundColor Green
} catch {
    Write-Host "[ERRO] Falha ao aplicar command/args via az rest" -ForegroundColor Red
    Write-Host $_
    Write-Host "[INFO] Workaround: tente trocar PATCH por PUT no script (ou me mande o erro completo do az rest)." -ForegroundColor Yellow
    exit 1
}
