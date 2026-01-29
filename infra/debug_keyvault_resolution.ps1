# Script para debugar resolução do Key Vault no container

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

# Carregar deploy_state.json
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado." -ForegroundColor Red
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

Write-Host "=== Debug: Key Vault Resolution ===" -ForegroundColor Cyan
Write-Host ""

# Teste: Verificar se a variável existe e seu formato
Write-Host "[TESTE] Verificando OPENAI_API_KEY..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Usar base64 para evitar problemas de escape
$testScript = @'
import os
import sys
k = os.getenv("OPENAI_API_KEY", "")
if not k:
    print("NOT_SET")
    sys.exit(1)
print(f"SET")
print(f"Length: {len(k)}")
print(f"Starts with @: {k.startswith('@')}")
print(f"Starts with sk-: {k.startswith('sk-')}")
if k.startswith('sk-'):
    print(f"First 20 chars: {k[:20]}...")
    sys.exit(0)
elif k.startswith('@'):
    print("KEYVAULT_REF_NOT_RESOLVED")
    sys.exit(2)
else:
    print("UNKNOWN_FORMAT")
    sys.exit(3)
'@

$scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($testScript)
$scriptBase64 = [Convert]::ToBase64String($scriptBytes)

# Usar aspas simples externas para evitar problemas
$testCmd = 'python -c "import base64, sys; exec(base64.b64decode(''' + $scriptBase64 + ''').decode(''utf-8''))"'

$testResult = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command $testCmd 2>&1

Write-Host "Resultado:" -ForegroundColor Gray
Write-Host $testResult
Write-Host ""

$ErrorActionPreference = "Stop"

Write-Host "=== Análise ===" -ForegroundColor Cyan
if ($testResult -match "SET" -and $testResult -match "Starts with sk-: True") {
    Write-Host "[OK] OPENAI_API_KEY está sendo resolvida corretamente!" -ForegroundColor Green
    Write-Host "[INFO] A chave está no formato correto e pronta para uso." -ForegroundColor Gray
} elseif ($testResult -match "KEYVAULT_REF_NOT_RESOLVED" -or ($testResult -match "SET" -and $testResult -match "Starts with @: True")) {
    Write-Host "[ERRO] A referência Key Vault NÃO está sendo resolvida!" -ForegroundColor Red
    Write-Host "[INFO] A variável ainda contém a referência '@Microsoft.KeyVault(...)'" -ForegroundColor Yellow
    Write-Host "[INFO] Isso significa que o Container Apps não está resolvendo a referência." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[INFO] Possíveis soluções:" -ForegroundColor Yellow
    Write-Host "  1. Aguardar mais tempo (pode levar até 15 minutos para resolução)" -ForegroundColor Gray
    Write-Host "  2. Reiniciar o Container App: az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision <latest>" -ForegroundColor Gray
    Write-Host "  3. Verificar se a Managed Identity tem permissões corretas no Key Vault" -ForegroundColor Gray
    Write-Host "  4. Verificar se não há firewall/restrições de rede bloqueando acesso ao Key Vault" -ForegroundColor Gray
} elseif ($testResult -match "NOT_SET") {
    Write-Host "[ERRO] OPENAI_API_KEY não está configurada no container!" -ForegroundColor Red
    Write-Host "[INFO] A variável de ambiente não existe." -ForegroundColor Yellow
} else {
    Write-Host "[AVISO] Não foi possível determinar o status completo da OPENAI_API_KEY!" -ForegroundColor Yellow
    Write-Host "[INFO] Verifique a saída acima para mais detalhes." -ForegroundColor Gray
}

Write-Host ""
