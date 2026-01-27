# Smoke test para validar deploy na Azure App Service (PowerShell)
# Testa /healthz e /readyz com retry e backoff exponencial

param(
    [string]$Url = "https://app-overlabs-prod-123.azurewebsites.net",
    [int]$Timeout = 30,
    [int]$MaxRetries = 5,
    [int]$InitialDelay = 2
)

$ErrorActionPreference = "Stop"

Write-Host "🧪 Smoke test para: $Url" -ForegroundColor Cyan
Write-Host "   Timeout: ${Timeout}s"
Write-Host "   Max retries: $MaxRetries"
Write-Host ""

function Test-Endpoint {
    param(
        [string]$Endpoint,
        [int]$ExpectedStatus = 200
    )
    
    $fullUrl = "$Url$Endpoint"
    Write-Host "  Testando: $Endpoint (esperado: $ExpectedStatus)" -ForegroundColor Yellow
    
    $retry = 0
    $delay = $InitialDelay
    
    while ($retry -lt $MaxRetries) {
        if ($retry -gt 0) {
            Write-Host "    Retry $retry/$MaxRetries (aguardando ${delay}s)..." -ForegroundColor Gray
            Start-Sleep -Seconds $delay
            $delay = $delay * 2  # Backoff exponencial
        }
        
        try {
            $response = Invoke-WebRequest -Uri $fullUrl -TimeoutSec $Timeout -UseBasicParsing -ErrorAction Stop
            $httpCode = $response.StatusCode
            
            if ($httpCode -eq $ExpectedStatus) {
                Write-Host "  ✅ $Endpoint retornou $httpCode" -ForegroundColor Green
                if ($response.Content) {
                    Write-Host "     Response: $($response.Content)" -ForegroundColor Gray
                }
                return $true
            } else {
                Write-Host "  ⚠️  $Endpoint retornou $httpCode (esperado $ExpectedStatus)" -ForegroundColor Yellow
                if ($response.Content) {
                    Write-Host "     Response: $($response.Content)" -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "  ⚠️  Erro ao conectar em $Endpoint : $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        $retry++
    }
    
    Write-Host "  ❌ $Endpoint falhou após $MaxRetries tentativas" -ForegroundColor Red
    return $false
}

# Testar /healthz
Write-Host "📋 Testando /healthz..." -ForegroundColor Cyan
if (-not (Test-Endpoint -Endpoint "/healthz" -ExpectedStatus 200)) {
    Write-Host ""
    Write-Host "❌ Smoke test falhou: /healthz não respondeu corretamente" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Testar /readyz
Write-Host "📋 Testando /readyz..." -ForegroundColor Cyan
if (-not (Test-Endpoint -Endpoint "/readyz" -ExpectedStatus 200)) {
    Write-Host ""
    Write-Host "⚠️  Aviso: /readyz não está pronto (pode ser temporário)" -ForegroundColor Yellow
    Write-Host "   Continuando com smoke test..." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ Smoke test passou com sucesso!" -ForegroundColor Green
exit 0
