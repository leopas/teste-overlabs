# Script para verificar se OPENAI_API_KEY está sendo resolvida corretamente no container

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar OPENAI_API_KEY no Container ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -ApiAppName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $ApiAppName) {
        $ApiAppName = $state.apiAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar configuração no Container App
Write-Host "[INFO] Verificando configuração no Container App..." -ForegroundColor Yellow
$openaiKeyRef = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='OPENAI_API_KEY'].value" -o tsv 2>&1

if ($openaiKeyRef -match "KeyVault") {
    Write-Host "[OK] OPENAI_API_KEY configurada com referência ao Key Vault" -ForegroundColor Green
    Write-Host "[INFO] Referência: $openaiKeyRef" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] OPENAI_API_KEY não está configurada como Key Vault reference!" -ForegroundColor Red
    Write-Host "[INFO] Valor encontrado: $openaiKeyRef" -ForegroundColor Gray
    exit 1
}
Write-Host ""

# 2. Verificar Managed Identity
Write-Host "[INFO] Verificando Managed Identity..." -ForegroundColor Yellow
$mi = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "identity" -o json 2>&1 | ConvertFrom-Json

if ($mi.type -eq "SystemAssigned" -or $mi.type -eq "UserAssigned, SystemAssigned") {
    Write-Host "[OK] Managed Identity habilitada: $($mi.type)" -ForegroundColor Green
    if ($mi.principalId) {
        Write-Host "[INFO] Principal ID: $($mi.principalId)" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERRO] Managed Identity não está habilitada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 3. Testar resolução da chave no container
Write-Host "[INFO] Testando resolução da chave no container..." -ForegroundColor Yellow
$testScript = @'
import os
key = os.getenv('OPENAI_API_KEY', 'NOT_SET')
if key == 'NOT_SET':
    print('NOT_SET')
    exit(1)
else:
    # Verificar se começa com sk- (formato OpenAI)
    if key.startswith('sk-'):
        print(f'OK: Key encontrada (length: {len(key)}, starts with sk-: True)')
        exit(0)
    else:
        print(f'WARNING: Key encontrada mas formato inesperado (length: {len(key)}, starts with sk-: False)')
        print(f'First 10 chars: {key[:10]}...')
        exit(1)
'@

$testBytes = [System.Text.Encoding]::UTF8.GetBytes($testScript)
$testBase64 = [Convert]::ToBase64String($testBytes)

# Usar método alternativo: criar arquivo temporário Python no container
$ErrorActionPreference = "Continue"

# Primeiro, criar o script Python no container
$createScriptCmd = "echo '$testScript' > /tmp/test_key.py"
az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command $createScriptCmd 2>&1 | Out-Null

# Depois executar
$testResult = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python /tmp/test_key.py" 2>&1

Write-Host $testResult

if ($testResult -match "OK:" -and $LASTEXITCODE -eq 0) {
    Write-Host "[OK] OPENAI_API_KEY está sendo resolvida corretamente no container!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] OPENAI_API_KEY não está sendo resolvida corretamente!" -ForegroundColor Red
    Write-Host "[INFO] Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Key Vault reference não está sendo resolvida" -ForegroundColor Gray
    Write-Host "  2. Managed Identity não tem permissões no Key Vault" -ForegroundColor Gray
    Write-Host "  3. Secret não existe no Key Vault" -ForegroundColor Gray
    Write-Host "  4. Container precisa ser reiniciado para aplicar mudanças" -ForegroundColor Gray
    exit 1
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 4. Testar chamada real à API OpenAI
Write-Host "[INFO] Testando chamada real à API OpenAI..." -ForegroundColor Yellow
$apiTestScript = @'
import os
import httpx
import sys

key = os.getenv('OPENAI_API_KEY', 'NOT_SET')
if key == 'NOT_SET' or not key.startswith('sk-'):
    print('ERRO: Key não configurada ou inválida')
    sys.exit(1)

try:
    response = httpx.get(
        'https://api.openai.com/v1/models',
        headers={'Authorization': f'Bearer {key}'},
        timeout=10.0
    )
    if response.status_code == 200:
        print(f'OK: API OpenAI respondeu com sucesso (status: {response.status_code})')
        sys.exit(0)
    else:
        print(f'ERRO: API OpenAI retornou status {response.status_code}')
        print(f'Resposta: {response.text[:200]}')
        sys.exit(1)
except Exception as e:
    print(f'ERRO: Falha ao chamar API: {e}')
    sys.exit(1)
'@

$apiTestBytes = [System.Text.Encoding]::UTF8.GetBytes($apiTestScript)
$apiTestBase64 = [Convert]::ToBase64String($apiTestBytes)

# Usar método alternativo: criar arquivo temporário Python no container
$ErrorActionPreference = "Continue"

# Primeiro, criar o script Python no container
$createApiScriptCmd = "echo '$apiTestScript' > /tmp/test_api.py"
az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command $createApiScriptCmd 2>&1 | Out-Null

# Depois executar
$apiTestResult = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python /tmp/test_api.py" 2>&1

Write-Host $apiTestResult

if ($apiTestResult -match "OK:" -and $LASTEXITCODE -eq 0) {
    Write-Host "[OK] API OpenAI está acessível com a chave configurada!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Falha ao chamar API OpenAI!" -ForegroundColor Red
    Write-Host "[INFO] A chave pode estar incorreta ou expirada no Key Vault" -ForegroundColor Yellow
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Verificação Concluída ===" -ForegroundColor Green
Write-Host "[OK] OPENAI_API_KEY está configurada e funcionando corretamente!" -ForegroundColor Green
