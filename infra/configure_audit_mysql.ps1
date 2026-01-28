# Script para configurar variáveis de ambiente de MySQL/audit no Container App
# Uso: .\infra\configure_audit_mysql.ps1 -MysqlHost "..." -MysqlUser "..." -MysqlPassword "..." -MysqlDatabase "..."

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [Parameter(Mandatory=$true)]
    [string]$MysqlHost,
    [Parameter(Mandatory=$true)]
    [string]$MysqlUser,
    [Parameter(Mandatory=$true)]
    [string]$MysqlPassword,
    [Parameter(Mandatory=$true)]
    [string]$MysqlDatabase,
    [string]$MysqlPort = "3306",
    [string]$KeyVaultName = $null,
    [switch]$UseKeyVault = $false
)

$ErrorActionPreference = "Stop"

Write-Host "=== Configurar Audit/MySQL no Container App ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] MySQL Host: $MysqlHost" -ForegroundColor Yellow
Write-Host "[INFO] MySQL Database: $MysqlDatabase" -ForegroundColor Yellow
Write-Host ""

# Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$ApiAppName' não encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# Preparar variáveis de ambiente
$envVars = @(
    "MYSQL_HOST=$MysqlHost",
    "MYSQL_PORT=$MysqlPort",
    "MYSQL_DATABASE=$MysqlDatabase",
    "MYSQL_USER=$MysqlUser",
    "TRACE_SINK=mysql",
    "AUDIT_LOG_ENABLED=1",
    "AUDIT_LOG_INCLUDE_TEXT=1",
    "AUDIT_LOG_RAW_MODE=risk_only"
)

# Configurar MYSQL_PASSWORD (Key Vault ou direto)
if ($UseKeyVault) {
    Write-Host "[INFO] Configurando MYSQL_PASSWORD via Key Vault..." -ForegroundColor Cyan
    
    # Verificar se secret já existe
    $ErrorActionPreference = "Continue"
    $secretExists = az keyvault secret show --vault-name $KeyVaultName --name "mysql-password" 2>$null
    $ErrorActionPreference = "Stop"
    
    if (-not $secretExists) {
        Write-Host "[INFO] Criando secret mysql-password no Key Vault..." -ForegroundColor Yellow
        az keyvault secret set `
            --vault-name $KeyVaultName `
            --name "mysql-password" `
            --value $MysqlPassword | Out-Null
        Write-Host "[OK] Secret criado" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Secret já existe, atualizando..." -ForegroundColor Yellow
        az keyvault secret set `
            --vault-name $KeyVaultName `
            --name "mysql-password" `
            --value $MysqlPassword | Out-Null
        Write-Host "[OK] Secret atualizado" -ForegroundColor Green
    }
    
    $envVars += "MYSQL_PASSWORD=@Microsoft.KeyVault(SecretUri=https://$KeyVaultName.vault.azure.net/secrets/mysql-password/)"
} else {
    Write-Host "[AVISO] Usando MYSQL_PASSWORD direto (não recomendado para produção)" -ForegroundColor Yellow
    $envVars += "MYSQL_PASSWORD=$MysqlPassword"
}

Write-Host ""
Write-Host "[INFO] Atualizando Container App com variáveis de ambiente..." -ForegroundColor Cyan

# Obter variáveis existentes
$existingEnv = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

# Adicionar novas variáveis mantendo as existentes
$allEnvVars = @()
foreach ($env in $existingEnv) {
    $name = $env.name
    # Não sobrescrever variáveis que vamos adicionar
    if ($envVars -notmatch "^$name=") {
        if ($env.secretRef) {
            $allEnvVars += "$name=@Microsoft.KeyVault(SecretUri=$($env.secretRef))"
        } else {
            $allEnvVars += "$name=$($env.value)"
        }
    }
}

# Adicionar novas variáveis
$allEnvVars += $envVars

# Atualizar Container App
az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars $allEnvVars | Out-Null

Write-Host "[OK] Container App atualizado" -ForegroundColor Green
Write-Host ""
Write-Host "=== Configuração Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Aplicar schema SQL no banco de dados:" -ForegroundColor Gray
Write-Host "     mysql -h $MysqlHost -u $MysqlUser -p < docs/db_audit_schema.sql" -ForegroundColor Cyan
Write-Host "  2. Verificar logs do Container App para confirmar conexão MySQL" -ForegroundColor Gray
Write-Host "  3. Fazer uma requisição de teste e verificar se grava no banco" -ForegroundColor Gray
Write-Host ""
