# Script rápido para adicionar federated credentials de environments
# Uso: .\infra\add_environment_credentials.ps1 -GitHubOrg "leopas" -GitHubRepo "teste-overlabs"

param(
    [Parameter(Mandatory=$true)]
    [string]$GitHubOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$GitHubRepo,
    
    [string]$AppName = "github-actions-rag-overlabs"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Adicionando Federated Credentials para Environments ===" -ForegroundColor Cyan
Write-Host ""

# Obter App ID
Write-Host "[INFO] Obtendo App ID..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$APP_ID = az ad app list --display-name $AppName --query "[0].appId" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $APP_ID) {
    Write-Host "[ERRO] App Registration '$AppName' não encontrado" -ForegroundColor Red
    Write-Host "   Execute primeiro: .\infra\setup_oidc.ps1 -GitHubOrg $GitHubOrg -GitHubRepo $GitHubRepo" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] App ID: $APP_ID" -ForegroundColor Green
Write-Host ""

# Criar federated credential para environment staging
Write-Host "[INFO] Verificando federated credential para environment staging..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$stagingEnvCredExists = az ad app federated-credential list --id $APP_ID --query "[?name=='github-actions-staging-env']" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($stagingEnvCredExists) {
    Write-Host "[OK] Federated credential para staging environment já existe" -ForegroundColor Green
} else {
    Write-Host "[INFO] Criando federated credential para staging environment..." -ForegroundColor Yellow
    $stagingEnvParams = @{
        name = "github-actions-staging-env"
        issuer = "https://token.actions.githubusercontent.com"
        subject = "repo:$GitHubOrg/$GitHubRepo`:environment:staging"
        audiences = @("api://AzureADTokenExchange")
    }
    
    $tempJsonFile = [System.IO.Path]::GetTempFileName()
    $stagingEnvParams | ConvertTo-Json -Compress | Out-File -FilePath $tempJsonFile -Encoding utf8 -NoNewline

    $ErrorActionPreference = "Continue"
    $stagingEnvError = az ad app federated-credential create `
      --id $APP_ID `
      --parameters "@$tempJsonFile" 2>&1 | Out-String
    $ErrorActionPreference = "Stop"
    
    Remove-Item $tempJsonFile -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Federated credential para staging environment criada" -ForegroundColor Green
    } else {
        if ($stagingEnvError -match "already exists" -or $stagingEnvError -match "Conflict") {
            Write-Host "[OK] Federated credential para staging environment já existe" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar federated credential para staging environment" -ForegroundColor Yellow
            Write-Host "   Detalhes: $($stagingEnvError.Trim())" -ForegroundColor Gray
        }
    }
}
Write-Host ""

# Criar federated credential para environment production
Write-Host "[INFO] Verificando federated credential para environment production..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$prodEnvCredExists = az ad app federated-credential list --id $APP_ID --query "[?name=='github-actions-production-env']" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($prodEnvCredExists) {
    Write-Host "[OK] Federated credential para production environment já existe" -ForegroundColor Green
} else {
    Write-Host "[INFO] Criando federated credential para production environment..." -ForegroundColor Yellow
    $prodEnvParams = @{
        name = "github-actions-production-env"
        issuer = "https://token.actions.githubusercontent.com"
        subject = "repo:$GitHubOrg/$GitHubRepo`:environment:production"
        audiences = @("api://AzureADTokenExchange")
    }
    
    $tempJsonFile = [System.IO.Path]::GetTempFileName()
    $prodEnvParams | ConvertTo-Json -Compress | Out-File -FilePath $tempJsonFile -Encoding utf8 -NoNewline

    $ErrorActionPreference = "Continue"
    $prodEnvError = az ad app federated-credential create `
      --id $APP_ID `
      --parameters "@$tempJsonFile" 2>&1 | Out-String
    $ErrorActionPreference = "Stop"
    
    Remove-Item $tempJsonFile -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Federated credential para production environment criada" -ForegroundColor Green
    } else {
        if ($prodEnvError -match "already exists" -or $prodEnvError -match "Conflict") {
            Write-Host "[OK] Federated credential para production environment já existe" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar federated credential para production environment" -ForegroundColor Yellow
            Write-Host "   Detalhes: $($prodEnvError.Trim())" -ForegroundColor Gray
        }
    }
}
Write-Host ""

Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Federated credentials para environments criadas." -ForegroundColor Cyan
Write-Host "A pipeline deve funcionar agora!" -ForegroundColor Cyan
Write-Host ""
