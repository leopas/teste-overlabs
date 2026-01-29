# Script simples para testar resolução do Key Vault

$rg = "rg-overlabs-prod"
$app = "app-overlabs-prod-248"

Write-Host "=== Teste de Resolucao do Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Script Python simples
$testScript = @'
import os
key = os.getenv('OPENAI_API_KEY')
if key:
    print(f'[OK] OPENAI_API_KEY esta definida')
    print(f'Length: {len(key)}')
    print(f'Preview: {key[:50]}...')
    if key.startswith('@Microsoft.KeyVault'):
        print('[ERRO] Key Vault reference NAO foi resolvida!')
        print('[INFO] A referencia ainda esta no formato original')
        exit(1)
    elif key.startswith('sk-'):
        print('[OK] Key parece estar resolvida corretamente (comeca com sk-)')
        exit(0)
    else:
        print('[AVISO] Key nao comeca com sk- ou @')
        print('[INFO] Pode estar resolvida mas com formato diferente')
        exit(0)
else:
    print('[ERRO] OPENAI_API_KEY nao esta definida!')
    exit(1)
'@

# Codificar em base64
$bytes = [System.Text.Encoding]::UTF8.GetBytes($testScript)
$base64 = [Convert]::ToBase64String($bytes)

Write-Host "[INFO] Executando teste no container..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$pythonCmd = "import base64, sys; exec(base64.b64decode('$base64').decode('utf-8'))"
$output = az containerapp exec `
    --name $app `
    --resource-group $rg `
    --command "python -c `"$pythonCmd`"" 2>&1

$exitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host $output
Write-Host ""

if ($exitCode -eq 0) {
    Write-Host "[OK] Key Vault reference foi resolvida!" -ForegroundColor Green
} elseif ($exitCode -eq 1) {
    Write-Host "[ERRO] Problema encontrado!" -ForegroundColor Red
    Write-Host ""
    Write-Host "[POSSIVEIS SOLUCOES]:" -ForegroundColor Yellow
    Write-Host "  1. Reinicie o Container App:" -ForegroundColor Gray
    Write-Host "     `$rev = az containerapp show --name $app --resource-group $rg --query 'properties.latestRevisionName' -o tsv" -ForegroundColor Gray
    Write-Host "     az containerapp revision restart --name $app --resource-group $rg --revision `$rev" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Aguarde alguns minutos para propagacao de permissoes" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Verifique permissoes novamente:" -ForegroundColor Gray
    Write-Host "     .\infra\audit_env_and_vault.ps1" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Nao foi possivel executar o teste" -ForegroundColor Yellow
}
