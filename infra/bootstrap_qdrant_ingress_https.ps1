# Script para configurar ingress HTTPS do Qdrant e apontar a API para o FQDN interno do ingress.
# Objetivo: em ACA com ingress HTTP, a API deve usar https://<fqdn-do-ingress> (porta 443) e não :6333.
#
# Uso:
#   .\infra\bootstrap_qdrant_ingress_https.ps1 `
#     -ResourceGroup "rg-overlabs-prod" `
#     -QdrantAppName "app-overlabs-qdrant-prod-300" `
#     -ApiAppName "app-overlabs-prod-300" `
#     -SetApiEnv `
#     -DryRun
#

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$QdrantAppName = "app-overlabs-qdrant-prod-300",
    [string]$ApiAppName = "app-overlabs-prod-300",

    # Default: true. Você pode passar -SetApiEnv:$false para não atualizar a API.
    [bool]$SetApiEnv = $true,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Args,

        [switch]$Silent
    )

    $cmdPreview = "az " + ($Args -join " ")
    if (-not $Silent) {
        Write-Host "[AZ] $cmdPreview" -ForegroundColor DarkGray
    }

    if ($DryRun) {
        return ""
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath "az" -ArgumentList $Args -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $stdout = ""
        $stderr = ""
        if (Test-Path $outFile) { $stdout = Get-Content $outFile -Raw }
        if (Test-Path $errFile) { $stderr = Get-Content $errFile -Raw }

        if ($p.ExitCode -ne 0) {
            throw ("AZ falhou (exit={0})`n{1}`n{2}" -f $p.ExitCode, $stderr.Trim(), $stdout.Trim())
        }

        return $stdout
    } finally {
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "=== Bootstrap Qdrant Ingress HTTPS (ACA) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Qdrant App: $QdrantAppName" -ForegroundColor Yellow
Write-Host "[INFO] API App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] SetApiEnv: $SetApiEnv" -ForegroundColor Yellow
Write-Host "[INFO] DryRun: $DryRun" -ForegroundColor Yellow
Write-Host ""

# A) Garantir ingress interno HTTP no Qdrant (targetPort 6333)
Write-Host "[INFO] Garantindo ingress internal+http no Qdrant (targetPort=6333)..." -ForegroundColor Yellow
Invoke-Az -Args @(
    "containerapp","ingress","enable",
    "-g",$ResourceGroup,
    "-n",$QdrantAppName,
    "--type","internal",
    "--transport","http",
    "--target-port","6333"
) | Out-Null

# B) Forçar HTTPS-only (allowInsecure=false)
Write-Host "[INFO] Forçando HTTPS-only no ingress do Qdrant (allowInsecure=false)..." -ForegroundColor Yellow
Invoke-Az -Args @(
    "containerapp","ingress","update",
    "-g",$ResourceGroup,
    "-n",$QdrantAppName,
    "--allow-insecure","false"
) | Out-Null

# C) Ler FQDN do ingress do Qdrant
Write-Host "[INFO] Lendo FQDN do ingress do Qdrant..." -ForegroundColor Yellow
$fqdn = (Invoke-Az -Args @(
    "containerapp","ingress","show",
    "-g",$ResourceGroup,
    "-n",$QdrantAppName,
    "--query","fqdn",
    "-o","tsv"
) -Silent).Trim()

if (-not $fqdn) {
    throw "FQDN do ingress do Qdrant veio vazio. Verifique o ingress do Container App."
}

Write-Host "[OK] FQDN do Qdrant: $fqdn" -ForegroundColor Green

# D) Atualizar QDRANT_URL na API
if ($SetApiEnv) {
    $qdrantUrl = "https://$fqdn"
    Write-Host "[INFO] Atualizando QDRANT_URL na API para HTTPS no FQDN do ingress..." -ForegroundColor Yellow
    Write-Host "  QDRANT_URL=$qdrantUrl" -ForegroundColor Gray

    Invoke-Az -Args @(
        "containerapp","update",
        "-g",$ResourceGroup,
        "-n",$ApiAppName,
        "--set-env-vars",
        "QDRANT_URL=$qdrantUrl"
    ) | Out-Null

    Write-Host "[OK] QDRANT_URL atualizado na API" -ForegroundColor Green
} else {
    Write-Host "[INFO] SetApiEnv=false, pulando update da API" -ForegroundColor Yellow
}

# E) Verificações pós-change
Write-Host ""
Write-Host "[INFO] Ingress do Qdrant (az containerapp ingress show)..." -ForegroundColor Cyan
Invoke-Az -Args @(
    "containerapp","ingress","show",
    "-g",$ResourceGroup,
    "-n",$QdrantAppName,
    "-o","json"
) -Silent | Write-Host

Write-Host ""
Write-Host "[INFO] QDRANT_URL atual na API..." -ForegroundColor Cyan
$apiQdrantUrl = (Invoke-Az -Args @(
    "containerapp","show",
    "-g",$ResourceGroup,
    "-n",$ApiAppName,
    "--query","properties.template.containers[0].env[?name=='QDRANT_URL'].value",
    "-o","tsv"
) -Silent).Trim()
Write-Host "  QDRANT_URL=$apiQdrantUrl" -ForegroundColor Gray

Write-Host ""
Write-Host "[INFO] Teste opcional /readyz (sem exec)..." -ForegroundColor Cyan
try {
    $apiFqdn = (Invoke-Az -Args @(
        "containerapp","ingress","show",
        "-g",$ResourceGroup,
        "-n",$ApiAppName,
        "--query","fqdn",
        "-o","tsv"
    ) -Silent).Trim()

    if ($apiFqdn) {
        $readyzUrl = "https://$apiFqdn/readyz"
        Write-Host "  GET $readyzUrl" -ForegroundColor Gray
        if (-not $DryRun) {
            $resp = Invoke-RestMethod -Method Get -Uri $readyzUrl -TimeoutSec 20
            Write-Host ("  response: {0}" -f ($resp | ConvertTo-Json -Compress)) -ForegroundColor Gray
        }
    } else {
        Write-Host "  [AVISO] API não tem ingress fqdn (talvez seja internal). Pulando teste." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [AVISO] Falha ao testar /readyz automaticamente. Rode manualmente e veja logs." -ForegroundColor Yellow
    Write-Host $_
}

Write-Host ""
Write-Host "=== Concluído ===" -ForegroundColor Green

