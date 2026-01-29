# Script para verificar e corrigir configuração da OPENAI_API_KEY no Container App

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar OPENAI_API_KEY no Container App ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $stateFile = ".azure/deploy_state.json"
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
    if (-not $KeyVaultName) {
        $KeyVaultName = $state.keyVaultName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar se OPENAI_API_KEY existe no Key Vault
Write-Host "[INFO] Verificando OPENAI_API_KEY no Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$secretExists = az keyvault secret show --vault-name $KeyVaultName --name "openai-api-key" --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $secretExists) {
    Write-Host "[AVISO] Secret 'openai-api-key' não encontrado no Key Vault" -ForegroundColor Yellow
    Write-Host "[INFO] Para criar, execute:" -ForegroundColor Cyan
    Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name 'openai-api-key' --value 'sk-...'" -ForegroundColor Gray
    Write-Host ""
    $create = Read-Host "Deseja criar o secret agora? (S/N)"
    if ($create -eq "S") {
        $keySecure = Read-Host "Digite a OPENAI_API_KEY (sk-...)" -AsSecureString
        $keyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($keySecure))
        az keyvault secret set --vault-name $KeyVaultName --name "openai-api-key" --value $keyPlain | Out-Null
        Write-Host "[OK] Secret criado no Key Vault" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Configure o secret manualmente antes de continuar." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[OK] Secret 'openai-api-key' existe no Key Vault" -ForegroundColor Green
}
Write-Host ""

# 2. Verificar se Container App tem referência ao Key Vault
Write-Host "[INFO] Verificando configuração no Container App..." -ForegroundColor Yellow
$appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

$hasOpenAIKey = $false
$openAIKeyValue = $null
foreach ($env in $appConfig) {
    if ($env.name -eq "OPENAI_API_KEY") {
        $hasOpenAIKey = $true
        $openAIKeyValue = $env.value
        break
    }
}

if (-not $hasOpenAIKey) {
    Write-Host "[AVISO] OPENAI_API_KEY não está configurada no Container App" -ForegroundColor Yellow
    Write-Host "[INFO] Adicionando referência ao Key Vault..." -ForegroundColor Cyan
    
    # Adicionar env var com referência ao Key Vault
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --set-env-vars "OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KeyVaultName.vault.azure.net/secrets/openai-api-key/)" 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] OPENAI_API_KEY configurada com referência ao Key Vault" -ForegroundColor Green
        Write-Host "[INFO] Aguardando 10s para a atualização ser aplicada..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    } else {
        Write-Host "[ERRO] Falha ao configurar OPENAI_API_KEY" -ForegroundColor Red
        exit 1
    }
} else {
    if ($openAIKeyValue -match "KeyVault") {
        Write-Host "[OK] OPENAI_API_KEY está configurada com referência ao Key Vault" -ForegroundColor Green
        Write-Host "  Referência: $openAIKeyValue" -ForegroundColor Gray
    } else {
        Write-Host "[AVISO] OPENAI_API_KEY está configurada mas não usa Key Vault" -ForegroundColor Yellow
        Write-Host "  Valor atual: $($openAIKeyValue.Substring(0, [Math]::Min(20, $openAIKeyValue.Length)))..." -ForegroundColor Gray
        Write-Host "[INFO] Recomendado: usar Key Vault para segurança" -ForegroundColor Yellow
    }
}
Write-Host ""

# 3. Testar se a chave funciona no container
Write-Host "[INFO] Testando OPENAI_API_KEY no container..." -ForegroundColor Yellow

# Criar script Python temporário para testar
$testScript = @'
import os
import sys
import httpx

key = os.getenv('OPENAI_API_KEY', 'NOT_SET')

if key == 'NOT_SET':
    print('[ERRO] OPENAI_API_KEY não encontrada')
    sys.exit(1)

print(f'[INFO] Key length: {len(key)}')
print(f'[INFO] Key starts with sk-: {key.startswith("sk-")}')

try:
    response = httpx.get(
        'https://api.openai.com/v1/models',
        headers={'Authorization': f'Bearer {key}'},
        timeout=10.0
    )
    if response.status_code == 200:
        print(f'[OK] Teste de conexão: {response.status_code}')
        print('[OK] OPENAI_API_KEY está funcionando!')
        sys.exit(0)
    else:
        print(f'[ERRO] Status code: {response.status_code}')
        print(f'[ERRO] Response: {response.text[:200]}')
        sys.exit(1)
except httpx.HTTPStatusError as e:
    print(f'[ERRO] HTTP Status Error: {e.response.status_code}')
    print(f'[ERRO] Response: {e.response.text[:200]}')
    sys.exit(1)
except Exception as e:
    print(f'[ERRO] Falha no teste: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
'@

# Salvar script temporário
$tempScript = [System.IO.Path]::GetTempFileName() + ".py"
$testScript | Out-File -FilePath $tempScript -Encoding utf8

# Copiar script para o container e executar
$ErrorActionPreference = "Continue"
Write-Host "[INFO] Executando teste de conexão..." -ForegroundColor Cyan

# Usar base64 para transferir o script de forma mais confiável
$scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($testScript))

$testOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"import base64, sys; exec(base64.b64decode('$scriptBase64').decode('utf-8'))\`"" 2>&1

Write-Host $testOutput

Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] OPENAI_API_KEY está funcionando!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] OPENAI_API_KEY não está funcionando ou está inválida" -ForegroundColor Red
    Write-Host "[INFO] Verifique se a chave no Key Vault está correta" -ForegroundColor Yellow
    Write-Host "[INFO] Para atualizar a chave:" -ForegroundColor Cyan
    Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name 'openai-api-key' --value 'sk-...'" -ForegroundColor Gray
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Verificação Concluída! ===" -ForegroundColor Green
Write-Host ""
