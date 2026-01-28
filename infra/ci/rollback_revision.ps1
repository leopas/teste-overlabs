# Script para rollback automático de uma revisão do Azure Container App
# Uso: .\infra\ci\rollback_revision.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -PrevRevisionName "app-overlabs-prod-XXX--prev123" -FailedRevisionName "app-overlabs-prod-XXX--failed123"

param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$PrevRevisionName,
    
    [Parameter(Mandatory=$true)]
    [string]$FailedRevisionName
)

$ErrorActionPreference = "Stop"

Write-Host "🚨 Iniciando ROLLBACK automático para o Container App '$AppName'..." -ForegroundColor Red
Write-Host "   Revisão anterior (para rollback): $PrevRevisionName" -ForegroundColor Yellow
Write-Host "   Revisão que falhou: $FailedRevisionName" -ForegroundColor Yellow
Write-Host ""

if ($PrevRevisionName -eq "none") {
    Write-Host "❌ Não há revisão anterior para fazer rollback. Este pode ser o primeiro deploy." -ForegroundColor Red
    Write-Host "   A intervenção manual é necessária." -ForegroundColor Yellow
    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## ⚠️ Rollback Manual Necessário
Não foi possível realizar o rollback automático pois não havia uma revisão anterior ativa.
Por favor, verifique o Container App **$AppName** no Azure Portal.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
    exit 1
}

Write-Host "🔄 Redirecionando 100% do tráfego para a revisão anterior: $PrevRevisionName" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
az containerapp ingress traffic set `
    --name "$AppName" `
    --resource-group "$ResourceGroup" `
    --revision-weight "${PrevRevisionName}=100" 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Erro ao redirecionar tráfego" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
Write-Host "✅ Tráfego redirecionado" -ForegroundColor Green

Write-Host "⏳ Aguardando 10s para o tráfego estabilizar..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host "🗑️ Desativando a revisão que falhou: $FailedRevisionName (opcional)" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
az containerapp revision deactivate `
    --name "$AppName" `
    --resource-group "$ResourceGroup" `
    --revision "$FailedRevisionName" 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "   (Não foi possível desativar a revisão $FailedRevisionName, pode já estar inativa ou ter outros problemas)" -ForegroundColor Yellow
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "✅ ROLLBACK CONCLUÍDO! Tráfego restaurado para $PrevRevisionName." -ForegroundColor Green

if ($env:GITHUB_STEP_SUMMARY) {
    @"
## ↩️ Rollback Automático Executado
O deploy falhou no smoke test. O tráfego foi revertido para a revisão anterior: **$PrevRevisionName**.
A revisão **$FailedRevisionName** foi desativada.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}
