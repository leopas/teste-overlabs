# Script para remover recursos antigos do App Service (migração para Container Apps)
# Uso: .\infra\cleanup_app_service.ps1 -ResourceGroup "rg-overlabs-prod" -Confirm:$false
#
# ATENÇÃO: Este script remove permanentemente:
# - App Service (Web App)
# - App Service Plan
# - Staging Slots
# - Azure Files mounts (mas NÃO o Storage Account/File Share)
#
# O script NÃO remove:
# - Resource Group
# - ACR (Container Registry)
# - Key Vault
# - Storage Account
# - File Share

param(
    [string]$ResourceGroup = $null,
    [switch]$Confirm = $true,
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"

Write-Host "=== Limpeza de Recursos App Service ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[AVISO] Este script irá remover permanentemente:" -ForegroundColor Yellow
Write-Host "  - App Service (Web App)" -ForegroundColor Red
Write-Host "  - App Service Plan" -ForegroundColor Red
Write-Host "  - Staging Slots" -ForegroundColor Red
Write-Host ""
Write-Host "[INFO] Recursos que NÃO serão removidos:" -ForegroundColor Green
Write-Host "  - Resource Group" -ForegroundColor Gray
Write-Host "  - ACR (Container Registry)" -ForegroundColor Gray
Write-Host "  - Key Vault" -ForegroundColor Gray
Write-Host "  - Storage Account" -ForegroundColor Gray
Write-Host "  - File Share" -ForegroundColor Gray
Write-Host ""

# Carregar deploy_state.json se ResourceGroup não for fornecido
if (-not $ResourceGroup) {
    $stateFile = ".azure/deploy_state.json"
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json
        $ResourceGroup = $state.resourceGroup
        
        # Verificar se é App Service ou Container Apps
        if ($state.appServiceName -and -not $state.apiAppName) {
            Write-Host "[INFO] Detectado deploy_state.json do App Service" -ForegroundColor Yellow
            Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
            Write-Host "  App Service: $($state.appServiceName)" -ForegroundColor Gray
            if ($state.appServicePlanName) {
                Write-Host "  App Service Plan: $($state.appServicePlanName)" -ForegroundColor Gray
            }
        } else {
            Write-Host "[INFO] deploy_state.json parece ser de Container Apps" -ForegroundColor Yellow
            Write-Host "  Se voce tem recursos App Service antigos, forneca -ResourceGroup manualmente" -ForegroundColor Yellow
            Write-Host ""
            $ResourceGroup = Read-Host "Digite o Resource Group que contém os recursos App Service (ou Enter para cancelar)"
            if (-not $ResourceGroup) {
                Write-Host "[INFO] Operação cancelada" -ForegroundColor Yellow
                exit 0
            }
        }
    } else {
        Write-Host "[ERRO] Arquivo .azure/deploy_state.json não encontrado" -ForegroundColor Red
        Write-Host "  Forneça -ResourceGroup ou execute o bootstrap primeiro" -ForegroundColor Yellow
        exit 1
    }
}

# Verificar se esta logado
Write-Host "[INFO] Verificando contexto Azure..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$account = az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Nao esta logado na Azure. Execute: az login" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"
Write-Host "[OK] Logado na Azure" -ForegroundColor Green
Write-Host ""

# Listar recursos App Service no Resource Group
Write-Host "[INFO] Procurando recursos App Service no Resource Group '$ResourceGroup'..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Listar Web Apps
$webAppsJson = az webapp list --resource-group $ResourceGroup --query "[].{name:name,state:state}" -o json 2>$null
$appServicePlansJson = az appservice plan list --resource-group $ResourceGroup --query "[].{name:name,sku:sku.name,tier:sku.tier}" -o json 2>$null

$ErrorActionPreference = "Stop"

$webApps = $null
$appServicePlans = $null

if ($webAppsJson -and $webAppsJson.Trim() -ne "" -and $webAppsJson.Trim() -ne "[]") {
    try {
        $webApps = $webAppsJson | ConvertFrom-Json
    } catch {
        $webApps = $null
    }
}

if ($appServicePlansJson -and $appServicePlansJson.Trim() -ne "" -and $appServicePlansJson.Trim() -ne "[]") {
    try {
        $appServicePlans = $appServicePlansJson | ConvertFrom-Json
    } catch {
        $appServicePlans = $null
    }
}

if (-not $webApps -and -not $appServicePlans) {
    Write-Host "[OK] Nenhum recurso App Service encontrado no Resource Group" -ForegroundColor Green
    Write-Host "  (Pode ja ter sido removido ou nunca existido)" -ForegroundColor Gray
    exit 0
}

Write-Host "[INFO] Recursos encontrados:" -ForegroundColor Cyan
if ($webApps) {
    Write-Host "  Web Apps:" -ForegroundColor Yellow
    foreach ($app in $webApps) {
        Write-Host "    - $($app.name) (Estado: $($app.state))" -ForegroundColor Gray
        
        # Listar slots
        $slots = az webapp deployment slot list --name $app.name --resource-group $ResourceGroup --query "[].name" -o tsv 2>$null
        if ($slots) {
            foreach ($slot in $slots) {
                Write-Host "      - Slot: $slot" -ForegroundColor DarkGray
            }
        }
    }
}

if ($appServicePlans) {
    Write-Host "  App Service Plans:" -ForegroundColor Yellow
    foreach ($plan in $appServicePlans) {
        Write-Host "    - $($plan.name) (SKU: $($plan.sku), Tier: $($plan.tier))" -ForegroundColor Gray
    }
}
Write-Host ""

# Confirmação
if (-not $Force) {
    if ($Confirm) {
        Write-Host "[AVISO] Voce esta prestes a remover permanentemente os recursos listados acima!" -ForegroundColor Red
        $response = Read-Host "Digite 'SIM' para confirmar (ou qualquer outra coisa para cancelar)"
        
        if ($response -ne "SIM") {
            Write-Host "[INFO] Operação cancelada pelo usuário" -ForegroundColor Yellow
            exit 0
        }
    }
}

Write-Host ""
Write-Host "[INFO] Iniciando remoção..." -ForegroundColor Yellow
Write-Host ""

# Remover Web Apps (e seus slots)
if ($webApps) {
    foreach ($app in $webApps) {
        Write-Host "[INFO] Removendo Web App: $($app.name)..." -ForegroundColor Yellow
        
        # Remover slots primeiro
        $ErrorActionPreference = "Continue"
        $slots = az webapp deployment slot list --name $app.name --resource-group $ResourceGroup --query "[].name" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($slots) {
            foreach ($slot in $slots) {
                Write-Host "  [INFO] Removendo slot: $slot..." -ForegroundColor Cyan
                $ErrorActionPreference = "Continue"
                az webapp deployment slot delete --name $app.name --resource-group $ResourceGroup --slot $slot --yes 2>&1 | Out-Null
                $ErrorActionPreference = "Stop"
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [OK] Slot '$slot' removido" -ForegroundColor Green
                } else {
                    Write-Host "  [AVISO] Erro ao remover slot '$slot' (pode já ter sido removido)" -ForegroundColor Yellow
                }
            }
        }
        
        # Remover Web App
        Write-Host "  [INFO] Removendo Web App..." -ForegroundColor Cyan
        $ErrorActionPreference = "Continue"
        az webapp delete --name $app.name --resource-group $ResourceGroup 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Web App '$($app.name)' removida" -ForegroundColor Green
        } else {
            Write-Host "  [AVISO] Erro ao remover Web App '$($app.name)'" -ForegroundColor Yellow
        }
    }
}

Write-Host ""

# Remover App Service Plans
if ($appServicePlans) {
    foreach ($plan in $appServicePlans) {
        Write-Host "[INFO] Removendo App Service Plan: $($plan.name)..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        az appservice plan delete --name $plan.name --resource-group $ResourceGroup --yes 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] App Service Plan '$($plan.name)' removido" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao remover App Service Plan '$($plan.name)'" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "=== Limpeza Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Recursos removidos:" -ForegroundColor Cyan
if ($webApps) {
    Write-Host "  - Web Apps e Slots" -ForegroundColor Gray
}
if ($appServicePlans) {
    Write-Host "  - App Service Plans" -ForegroundColor Gray
}
Write-Host ""
Write-Host "[INFO] Recursos mantidos (ainda em uso):" -ForegroundColor Green
Write-Host "  - Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  - ACR (Container Registry)" -ForegroundColor Gray
Write-Host "  - Key Vault" -ForegroundColor Gray
Write-Host "  - Storage Account e File Share" -ForegroundColor Gray
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Execute o bootstrap para Container Apps:" -ForegroundColor Gray
Write-Host "     .\infra\bootstrap_container_apps.ps1 -EnvFile .env -Stage prod -Location brazilsouth" -ForegroundColor Cyan
Write-Host "  2. Atualize o workflow do GitHub Actions para Container Apps" -ForegroundColor Gray
Write-Host ""
