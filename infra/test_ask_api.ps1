# Script para testar a API /ask no Azure
# Uso: .\infra\test_ask_api.ps1 -Question "Qual é a política de reembolso?" -Slot staging

param(
    [Parameter(Mandatory=$true)]
    [string]$Question,
    
    [string]$Slot = "production",  # "production" ou "staging"
    
    [string]$WebApp = $null,
    [string]$ResourceGroup = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Teste da API /ask ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se parâmetros não forem fornecidos
if (-not $WebApp -or -not $ResourceGroup) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -WebApp e -ResourceGroup." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    $WebApp = $state.appServiceName
    $ResourceGroup = $state.resourceGroup
}

# Construir URL
if ($Slot -eq "staging") {
    $baseUrl = "https://${WebApp}-staging.azurewebsites.net"
} else {
    $baseUrl = "https://${WebApp}.azurewebsites.net"
}

$url = "$baseUrl/ask"

Write-Host "[INFO] Testando endpoint: $url" -ForegroundColor Yellow
Write-Host "[INFO] Pergunta: $Question" -ForegroundColor Yellow
Write-Host ""

# Validar tamanho da pergunta
if ($Question.Length -lt 3) {
    Write-Host "[ERRO] A pergunta deve ter pelo menos 3 caracteres" -ForegroundColor Red
    exit 1
}

if ($Question.Length -gt 2000) {
    Write-Host "[ERRO] A pergunta deve ter no máximo 2000 caracteres" -ForegroundColor Red
    exit 1
}

# Criar payload JSON
$payload = @{
    question = $Question
} | ConvertTo-Json -Compress

Write-Host "[INFO] Enviando requisição..." -ForegroundColor Cyan
Write-Host ""

# Executar curl (usando Invoke-RestMethod do PowerShell que é mais confiável)
try {
    $headers = @{
        "Content-Type" = "application/json"
        "Accept" = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri $url -Method Post -Body $payload -Headers $headers -ErrorAction Stop
    
    Write-Host "[OK] Resposta recebida:" -ForegroundColor Green
    Write-Host ""
    
    # Formatar resposta
    $response | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor Cyan
    
    Write-Host ""
    Write-Host "[INFO] Resumo:" -ForegroundColor Yellow
    Write-Host "  Answer: $($response.answer.Substring(0, [Math]::Min(100, $response.answer.Length)))..." -ForegroundColor Gray
    Write-Host "  Confidence: $($response.confidence)" -ForegroundColor Gray
    Write-Host "  Sources: $($response.sources.Count)" -ForegroundColor Gray
    
} catch {
    Write-Host "[ERRO] Falha na requisição:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  Status Code: $statusCode" -ForegroundColor Yellow
        
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorBody = $reader.ReadToEnd()
            Write-Host "  Response: $errorBody" -ForegroundColor Yellow
        } catch {
            Write-Host "  (Não foi possível ler o corpo da resposta de erro)" -ForegroundColor Gray
        }
    }
    
    exit 1
}

Write-Host ""
Write-Host "=== Teste Concluído ===" -ForegroundColor Green
