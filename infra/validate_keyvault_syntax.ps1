# Script de validação para CI/CD: Verifica se há sintaxe incorreta de Key Vault
# Falha se encontrar @Microsoft.KeyVault em YAMLs de Container Apps
# Uso: .\infra\validate_keyvault_syntax.ps1

param(
    [string]$RootPath = "."
)

$ErrorActionPreference = "Stop"

Write-Host "=== Validação: Sintaxe de Key Vault em Container Apps ===" -ForegroundColor Cyan
Write-Host ""

$errors = @()
$warnings = @()

# 1. Verificar YAMLs de Container Apps (qualquer YAML com @Microsoft.KeyVault falha)
Write-Host "[1/3] Verificando YAMLs de Container Apps..." -ForegroundColor Yellow
$yamlFiles = Get-ChildItem -Path $RootPath -Filter "*.yaml" -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch "node_modules|\.git|\.venv|__pycache__"
}

foreach ($file in $yamlFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match '@Microsoft\.KeyVault') {
        $errors += "YAML: $($file.FullName) contém @Microsoft.KeyVault (linha ~$($content.IndexOf('@Microsoft.KeyVault')))"
    }
    # Falhar se env tiver value: com @Microsoft.KeyVault (sintaxe App Service)
    if ($content -match 'value:\s*["'']?@Microsoft\.KeyVault') {
        $errors += "YAML: $($file.FullName) contém env com value: @Microsoft.KeyVault (use secretRef + keyVaultUrl)"
    }
}

# 2. Verificar scripts PowerShell que geram YAMLs
Write-Host "[2/3] Verificando scripts PowerShell..." -ForegroundColor Yellow
$ps1Files = Get-ChildItem -Path $RootPath -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch "node_modules|\.git|\.venv|__pycache__|old\\"
}

foreach ($file in $ps1Files) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    # Verificar se injeta @Microsoft.KeyVault em YAMLs ou env vars
    if ($content -match '@Microsoft\.KeyVault.*SecretUri' -and 
        $content -notmatch 'fix_keyvault|check_keyvault|diagnose|verify|old\\') {
        # Verificar se é apenas detecção/correção (OK) ou injeção (ERRO)
        if ($content -match 'envVars\s*\+=.*@Microsoft\.KeyVault' -or
            $content -match 'value.*@Microsoft\.KeyVault' -or
            $content -match 'yamlContent.*@Microsoft\.KeyVault') {
            $errors += "PowerShell: $($file.FullName) injeta @Microsoft.KeyVault em YAML/env vars"
        }
    }
}

# 3. Verificar Bicep
Write-Host "[3/3] Verificando arquivos Bicep..." -ForegroundColor Yellow
$bicepFiles = Get-ChildItem -Path $RootPath -Filter "*.bicep" -Recurse -ErrorAction SilentlyContinue
foreach ($file in $bicepFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match '@Microsoft\.KeyVault') {
        $errors += "Bicep: $($file.FullName) contém @Microsoft.KeyVault"
    }
    # Verificar se secrets têm identity definida quando keyVaultUrl está presente
    if ($content -match 'keyVaultUrl:' -and $content -notmatch 'identity:\s*[\''"]system[\''"]') {
        $warnings += "Bicep: $($file.FullName) tem keyVaultUrl mas pode não ter identity definida"
    }
}

# 4. Verificar se secrets com value: literal são não-secretos
Write-Host "[EXTRA] Verificando secrets com value: literal..." -ForegroundColor Yellow
foreach ($file in $yamlFiles) {
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match 'secrets:\s*\n\s*-\s*name:.*\n\s*value:') {
        # Verificar se é um secret (não deveria ter value:)
        $lines = Get-Content $file.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'secrets:' -or $lines[$i] -match '^\s*-\s*name:') {
                # Próximas linhas podem ter value:
                if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*value:' -and 
                    $lines[$i] -match 'name:\s*(mysql-password|openai-api-key|audit-enc|.*password|.*key|.*secret)') {
                    $warnings += "YAML: $($file.FullName) linha $($i+2): Secret com value: literal (deveria usar keyVaultUrl ou secretRef)"
                }
            }
        }
    }
}

# Resumo
Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host ""

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "[OK] Nenhum problema encontrado!" -ForegroundColor Green
    exit 0
}

if ($errors.Count -gt 0) {
    Write-Host "[ERRO] Problemas encontrados ($($errors.Count)):" -ForegroundColor Red
    foreach ($error in $errors) {
        Write-Host "  - $error" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Corrija os problemas acima antes de fazer commit." -ForegroundColor Yellow
}

if ($warnings.Count -gt 0) {
    Write-Host "[AVISO] Avisos encontrados ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}

if ($errors.Count -gt 0) {
    exit 1
} else {
    exit 0
}
