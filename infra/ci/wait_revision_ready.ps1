# Script para polling de readiness de uma revisão do Azure Container App
# Uso: .\infra\ci\wait_revision_ready.ps1 -AppName "app-overlabs-prod-XXX" -ResourceGroup "rg-overlabs-prod" -RevisionName "app-overlabs-prod-XXX--abc123" -TimeoutSeconds 300

param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$RevisionName,
    
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

Write-Host "⏳ Iniciando polling para revisão '$RevisionName' do Container App '$AppName'..." -ForegroundColor Cyan
Write-Host "   Timeout: ${TimeoutSeconds}s" -ForegroundColor Yellow
Write-Host ""

$startTime = Get-Date
$endTime = $startTime.AddSeconds($TimeoutSeconds)
$delay = 5 # Segundos de delay inicial

while ((Get-Date) -lt $endTime) {
    $elapsedTime = [int]((Get-Date) - $startTime).TotalSeconds
    Write-Host "   Aguardando readiness (tempo decorrido: ${elapsedTime}s)..." -ForegroundColor Gray
    
    # 1. Verificar Provisioning State
    $ErrorActionPreference = "Continue"
    $provState = az containerapp revision show `
        --name "$AppName" `
        --resource-group "$ResourceGroup" `
        --revision "$RevisionName" `
        --query "properties.provisioningState" -o tsv 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   ⚠️  Erro ao obter estado da revisão. Aguardando..." -ForegroundColor Yellow
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 30) # Backoff exponencial, máximo 30s
        continue
    }
    
    $ErrorActionPreference = "Stop"
    
    if ($provState -eq "Succeeded") {
        Write-Host "   ✅ Provisioning State: Succeeded" -ForegroundColor Green
        
        # 2. Verificar Running State
        $ErrorActionPreference = "Continue"
        $runState = az containerapp revision show `
            --name "$AppName" `
            --resource-group "$ResourceGroup" `
            --revision "$RevisionName" `
            --query "properties.runningState" -o tsv 2>$null
        
        $ErrorActionPreference = "Stop"
        
        if ($runState -eq "Running") {
            Write-Host "   ✅ Running State: Running" -ForegroundColor Green
            Write-Host ""
            Write-Host "   ✅ Revisão '$RevisionName' está pronta!" -ForegroundColor Green
            exit 0
        } elseif ($runState -eq "Failed") {
            Write-Host "   ❌ Running State: Failed. Revisão falhou ao iniciar." -ForegroundColor Red
            exit 1
        } else {
            Write-Host "   ⚠️  Running State: $runState. Aguardando..." -ForegroundColor Yellow
        }
    } elseif ($provState -eq "Failed") {
        Write-Host "   ❌ Provisioning State: Failed. Revisão falhou ao provisionar." -ForegroundColor Red
        exit 1
    } else {
        Write-Host "   ⚠️  Provisioning State: $provState. Aguardando..." -ForegroundColor Yellow
    }
    
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, 30) # Backoff exponencial, máximo 30s
}

$elapsedTime = [int]((Get-Date) - $startTime).TotalSeconds
Write-Host ""
Write-Host "❌ Timeout de ${TimeoutSeconds}s atingido. Revisão '$RevisionName' não ficou pronta." -ForegroundColor Red
Write-Host "   Tempo decorrido: ${elapsedTime}s" -ForegroundColor Yellow
exit 1
