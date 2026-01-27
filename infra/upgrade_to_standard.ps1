# Script para fazer upgrade do App Service Plan de Basic (B1) para Standard (S1)
# Uso: .\infra\upgrade_to_standard.ps1 -AppServicePlanName "asp-overlabs-prod-282" -ResourceGroup "rg-overlabs-prod"

param(
    [Parameter(Mandatory=$true)]
    [string]$AppServicePlanName,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [string]$Sku = "S1"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Upgrade App Service Plan para Standard ===" -ForegroundColor Cyan
Write-Host ""

# Verificar se está logado
Write-Host "[INFO] Verificando contexto Azure..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$account = az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Não está logado na Azure. Execute: az login" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"

# Verificar se o plano existe
Write-Host "[INFO] Verificando App Service Plan..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$planInfo = az appservice plan show --name $AppServicePlanName --resource-group $ResourceGroup --query "{sku:sku.name, tier:sku.tier}" -o json 2>&1
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] App Service Plan '$AppServicePlanName' não encontrado no Resource Group '$ResourceGroup'" -ForegroundColor Red
    exit 1
}

$planJson = $planInfo | ConvertFrom-Json
$currentSku = $planJson.sku
$currentTier = $planJson.tier

Write-Host "[OK] Plano encontrado" -ForegroundColor Green
Write-Host "  SKU atual: $currentSku ($currentTier)" -ForegroundColor Cyan
Write-Host ""

# Verificar se já é Standard ou superior
if ($currentTier -eq "Standard" -or $currentTier -eq "Premium" -or $currentTier -eq "PremiumV2" -or $currentTier -eq "PremiumV3") {
    Write-Host "[OK] O plano já está no tier '$currentTier' (suporta slots)" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Verificando se staging slot existe..." -ForegroundColor Yellow
    
    # Obter nome da Web App
    $ErrorActionPreference = "Continue"
    $webApps = az webapp list --resource-group $ResourceGroup --query "[?appServicePlanId=='/subscriptions/*/resourceGroups/$ResourceGroup/providers/Microsoft.Web/serverfarms/$AppServicePlanName'].name" -o tsv 2>&1
    $ErrorActionPreference = "Stop"
    
    if ($webApps) {
        $webAppName = ($webApps -split "`n")[0]
        Write-Host "  Web App: $webAppName" -ForegroundColor Cyan
        
        $ErrorActionPreference = "Continue"
        $slotExists = az webapp deployment slot list --name $webAppName --resource-group $ResourceGroup --query "[?name=='staging'].name" -o tsv 2>&1
        $ErrorActionPreference = "Stop"
        
        if ($slotExists) {
            Write-Host "[OK] Staging slot já existe" -ForegroundColor Green
        } else {
            Write-Host "[INFO] Criando staging slot..." -ForegroundColor Yellow
            $ErrorActionPreference = "Continue"
            az webapp deployment slot create --name $webAppName --resource-group $ResourceGroup --slot staging --configuration-source $webAppName 2>&1 | Out-Null
            $ErrorActionPreference = "Stop"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] Staging slot criado" -ForegroundColor Green
            } else {
                Write-Host "[AVISO] Erro ao criar staging slot" -ForegroundColor Yellow
            }
        }
    }
    
    exit 0
}

# Confirmar upgrade
Write-Host "[AVISO] Este upgrade irá:" -ForegroundColor Yellow
Write-Host "  - Mudar o SKU de $currentSku para $Sku" -ForegroundColor Yellow
Write-Host "  - Aumentar o custo mensal (Standard é mais caro que Basic)" -ForegroundColor Yellow
Write-Host "  - Permitir uso de deployment slots" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Deseja continuar? (S/N)"

if ($confirm -ne "S" -and $confirm -ne "s" -and $confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "[INFO] Upgrade cancelado" -ForegroundColor Yellow
    exit 0
}

# Fazer upgrade
Write-Host ""
Write-Host "[INFO] Fazendo upgrade para $Sku..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az appservice plan update --name $AppServicePlanName --resource-group $ResourceGroup --sku $Sku 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Upgrade concluído!" -ForegroundColor Green
    Write-Host ""
    
    # Verificar SKU atualizado
    $ErrorActionPreference = "Continue"
    $newPlanInfo = az appservice plan show --name $AppServicePlanName --resource-group $ResourceGroup --query "{sku:sku.name, tier:sku.tier}" -o json 2>&1
    $ErrorActionPreference = "Stop"
    
    if ($LASTEXITCODE -eq 0) {
        $newPlanJson = $newPlanInfo | ConvertFrom-Json
        Write-Host "[OK] SKU atualizado para: $($newPlanJson.sku) ($($newPlanJson.tier))" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
    Write-Host "  1. Criar staging slot (se ainda não existir)" -ForegroundColor Yellow
    Write-Host "  2. A pipeline do GitHub Actions detectará automaticamente o slot" -ForegroundColor Yellow
    Write-Host ""
    
    # Criar staging slot
    $ErrorActionPreference = "Continue"
    $webApps = az webapp list --resource-group $ResourceGroup --query "[?appServicePlanId=='/subscriptions/*/resourceGroups/$ResourceGroup/providers/Microsoft.Web/serverfarms/$AppServicePlanName'].name" -o tsv 2>&1
    $ErrorActionPreference = "Stop"
    
    if ($webApps) {
        $webAppName = ($webApps -split "`n")[0]
        Write-Host "[INFO] Criando staging slot para $webAppName..." -ForegroundColor Yellow
        
        $ErrorActionPreference = "Continue"
        $slotExists = az webapp deployment slot list --name $webAppName --resource-group $ResourceGroup --query "[?name=='staging'].name" -o tsv 2>&1
        $ErrorActionPreference = "Stop"
        
        if (-not $slotExists) {
            $ErrorActionPreference = "Continue"
            az webapp deployment slot create --name $webAppName --resource-group $ResourceGroup --slot staging --configuration-source $webAppName 2>&1 | Out-Null
            $ErrorActionPreference = "Stop"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] Staging slot criado" -ForegroundColor Green
            } else {
                Write-Host "[AVISO] Erro ao criar staging slot. Execute manualmente:" -ForegroundColor Yellow
                Write-Host "  az webapp deployment slot create --name $webAppName --resource-group $ResourceGroup --slot staging --configuration-source $webAppName" -ForegroundColor Gray
            }
        } else {
            Write-Host "[OK] Staging slot já existe" -ForegroundColor Green
        }
    }
    
} else {
    Write-Host "[ERRO] Falha ao fazer upgrade" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
