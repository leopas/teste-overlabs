# Script para diagnosticar problemas de acesso ao Key Vault do container

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVault = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== DIAGNÓSTICO: Acesso ao Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVault) {
    $stateFile = ".azure/deploy_state.json"
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
    if (-not $KeyVault) {
        $KeyVault = $state.keyVaultName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVault" -ForegroundColor Yellow
Write-Host ""

# 1. Verificar Managed Identity
Write-Host "=== 1. MANAGED IDENTITY ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$miPrincipalId = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.principalId" -o tsv 2>$null
$miType = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity.type" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($miPrincipalId) {
    Write-Host "[OK] Managed Identity habilitada" -ForegroundColor Green
    Write-Host "  Principal ID: $miPrincipalId" -ForegroundColor Gray
    Write-Host "  Tipo: $miType" -ForegroundColor Gray
} else {
    Write-Host "[ERRO] Managed Identity NÃO está habilitada!" -ForegroundColor Red
    Write-Host "[AÇÃO] Execute: .\infra\fix_managed_identity.ps1" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 2. Verificar Key Vault reference no Container App
Write-Host "=== 2. KEY VAULT REFERENCE NO CONTAINER APP ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$containerEnv = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

$openaiKvRef = $null
if ($containerEnv) {
    foreach ($env in $containerEnv) {
        if ($env.name -eq "OPENAI_API_KEY") {
            $openaiKvRef = $env.value
            break
        }
    }
}

if ($openaiKvRef) {
    Write-Host "[OK] OPENAI_API_KEY configurada como Key Vault reference" -ForegroundColor Green
    Write-Host "  Referência: $openaiKvRef" -ForegroundColor Gray
    
    # Extrair nome do secret
    if ($openaiKvRef -match 'secrets/([^/]+)') {
        $secretName = $matches[1]
        Write-Host "  Secret name: $secretName" -ForegroundColor Gray
    } else {
        Write-Host "[ERRO] Formato de Key Vault reference invalido!" -ForegroundColor Red
        Write-Host '  Formato esperado: @Microsoft.KeyVault(SecretUri=https://vault.vault.azure.net/secrets/name/)' -ForegroundColor Gray
    }
} else {
    Write-Host '[ERRO] OPENAI_API_KEY nao esta configurada como Key Vault reference!' -ForegroundColor Red
    Write-Host "[AÇÃO] Execute: .\infra\bootstrap_api.ps1 para reconfigurar" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 3. Verificar se o secret existe no Key Vault
Write-Host "=== 3. SECRET NO KEY VAULT ===" -ForegroundColor Cyan
if ($secretName) {
    $ErrorActionPreference = "Continue"
    $secretExists = az keyvault secret show --vault-name $KeyVault --name $secretName --query "name" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($secretExists) {
        Write-Host "[OK] Secret '$secretName' existe no Key Vault" -ForegroundColor Green
        
        # Verificar se tem valor (sem mostrar o valor)
        $ErrorActionPreference = "Continue"
        $hasValue = az keyvault secret show --vault-name $KeyVault --name $secretName --query "value" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($hasValue) {
            Write-Host "[OK] Secret tem valor configurado" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Secret existe mas pode não ter valor" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERRO] Secret '$secretName' NÃO existe no Key Vault!" -ForegroundColor Red
        Write-Host "[AÇÃO] Crie o secret no Key Vault:" -ForegroundColor Yellow
        Write-Host "  az keyvault secret set --vault-name $KeyVault --name $secretName --value '<sua-chave-openai>'" -ForegroundColor Gray
        exit 1
    }
} else {
    Write-Host '[AVISO] Nao foi possivel extrair nome do secret da referencia' -ForegroundColor Yellow
}
Write-Host ""

# 4. Verificar permissões RBAC no Key Vault
Write-Host "=== 4. PERMISSÕES RBAC NO KEY VAULT ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$kvRbacEnabled = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($kvRbacEnabled -eq $true) {
    Write-Host "[INFO] Key Vault usa RBAC" -ForegroundColor Yellow
    
    $subscriptionId = az account show --query id -o tsv
    $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"
    
    $ErrorActionPreference = "Continue"
    $rbacRoles = az role assignment list --scope $kvResourceId --assignee $miPrincipalId --query "[].roleDefinitionName" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($rbacRoles) {
        Write-Host "[OK] Permissões RBAC encontradas:" -ForegroundColor Green
        $rbacRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        
        $hasSecretsUser = $rbacRoles | Where-Object { $_ -like "*Key Vault Secrets User*" -or $_ -like "*Secrets User*" }
        if (-not $hasSecretsUser) {
            Write-Host "[ERRO] Role 'Key Vault Secrets User' NÃO encontrada!" -ForegroundColor Red
            Write-Host "[AÇÃO] Execute: .\infra\fix_keyvault_rbac.ps1" -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "[OK] Role 'Key Vault Secrets User' configurada" -ForegroundColor Green
        }
    } else {
        Write-Host "[ERRO] Nenhuma permissão RBAC encontrada!" -ForegroundColor Red
        Write-Host "[AÇÃO] Execute: .\infra\fix_keyvault_rbac.ps1" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host '[INFO] Key Vault usa Access Policies (metodo antigo)' -ForegroundColor Yellow
    Write-Host '[AVISO] Este Key Vault deveria usar RBAC. Considere migrar.' -ForegroundColor Yellow
}
Write-Host ""

# 5. Testar resolução do secret dentro do container
Write-Host "=== 5. TESTE DE RESOLUCAO NO CONTAINER ===" -ForegroundColor Cyan
Write-Host "[INFO] Testando se o container consegue resolver o Key Vault reference..." -ForegroundColor Yellow

# Usar método exato do verify_openai_key.ps1
$testScript = @'
import os
import sys
key = os.getenv('OPENAI_API_KEY', 'NOT_SET')
if key != 'NOT_SET':
    preview = key[:20] if len(key) > 20 else key
    print(f'OPENAI_API_KEY value: {preview}...')
    print(f'Length: {len(key)}')
else:
    print('OPENAI_API_KEY value: NOT_SET')
    print('Length: 0')
if key.startswith('@Microsoft.KeyVault'):
    print('[INFO] Key Vault reference detectada')
    print('[AVISO] Referencia nao foi resolvida pelo Azure!')
    sys.exit(1)
elif key == 'NOT_SET':
    print('[ERRO] OPENAI_API_KEY nao esta definida!')
    sys.exit(1)
elif len(key) < 10:
    print('[ERRO] OPENAI_API_KEY parece estar vazia ou invalida!')
    sys.exit(1)
else:
    print('[OK] OPENAI_API_KEY parece estar resolvida corretamente')
    sys.exit(0)
'@

# Usar base64 para transferir o script de forma mais confiável
$scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($testScript))

$ErrorActionPreference = "Continue"
$testOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"import base64, sys; exec(base64.b64decode('$scriptBase64').decode('utf-8'))\`"" 2>&1

$testExitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

Write-Host $testOutput

if ($testExitCode -eq 0) {
    Write-Host "[OK] Container consegue resolver o Key Vault reference!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Container NÃO consegue resolver o Key Vault reference!" -ForegroundColor Red
    Write-Host ""
    Write-Host "[POSSÍVEIS CAUSAS]:" -ForegroundColor Yellow
    Write-Host "  1. Managed Identity não tem permissões corretas" -ForegroundColor Gray
    Write-Host "  2. Key Vault reference está malformada" -ForegroundColor Gray
    Write-Host "  3. Container App precisa ser reiniciado para aplicar mudanças" -ForegroundColor Gray
    Write-Host "  4. Key Vault está em outra subscription/tenant" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[AÇÕES RECOMENDADAS]:" -ForegroundColor Yellow
    Write-Host "  1. Verifique permissões: .\infra\audit_env_and_vault.ps1" -ForegroundColor Gray
    Write-Host "  2. Reinicie o Container App:" -ForegroundColor Gray
    Write-Host "     `$rev = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query 'properties.latestRevisionName' -o tsv" -ForegroundColor Gray
    Write-Host "     az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision `$rev" -ForegroundColor Gray
}
Write-Host ""

# 6. Verificar logs do container para erros relacionados ao Key Vault
Write-Host '=== 6. LOGS DO CONTAINER ===' -ForegroundColor Cyan
Write-Host '[INFO] Procurando erros relacionados ao Key Vault...' -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$logs = az containerapp logs show --name $ApiAppName --resource-group $ResourceGroup --tail 50 --type console 2>$null
$ErrorActionPreference = "Stop"

$pattern = 'keyvault|key vault|secret|authorization|permission|401|403|unauthorized'
$kvErrors = $logs | Select-String -Pattern $pattern -CaseSensitive:$false

if ($kvErrors) {
    Write-Host "[AVISO] Possíveis erros relacionados ao Key Vault encontrados nos logs:" -ForegroundColor Yellow
    $kvErrors | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    Write-Host "[INFO] Nenhum erro óbvio relacionado ao Key Vault encontrado nos logs recentes" -ForegroundColor Green
}
Write-Host ""

# 7. Resumo final
Write-Host "=== RESUMO DO DIAGNÓSTICO ===" -ForegroundColor Cyan
Write-Host ""

$allOk = $true
if (-not $miPrincipalId) {
    Write-Host "[ERRO] Managed Identity não habilitada" -ForegroundColor Red
    $allOk = $false
}
if (-not $openaiKvRef) {
    Write-Host "[ERRO] Key Vault reference não configurada" -ForegroundColor Red
    $allOk = $false
}
if ($secretName -and -not $secretExists) {
    Write-Host "[ERRO] Secret não existe no Key Vault" -ForegroundColor Red
    $allOk = $false
}
if ($kvRbacEnabled -eq $true -and -not $hasSecretsUser) {
    Write-Host "[ERRO] Permissões RBAC não configuradas" -ForegroundColor Red
    $allOk = $false
}
if ($testExitCode -ne 0) {
    Write-Host "[ERRO] Container não consegue resolver Key Vault reference" -ForegroundColor Red
    $allOk = $false
}

if ($allOk) {
    Write-Host "[OK] Tudo parece estar configurado corretamente!" -ForegroundColor Green
    Write-Host "[INFO] Se ainda houver problemas, tente reiniciar o Container App" -ForegroundColor Cyan
} else {
    Write-Host "[AVISO] Problemas encontrados. Siga as acoes recomendadas acima." -ForegroundColor Yellow
}
Write-Host ""
