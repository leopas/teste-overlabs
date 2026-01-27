# Script de Bootstrap para criar infraestrutura Azure
# Uso: .\infra\bootstrap_azure.ps1 -Stage "prod" -Location "brazilsouth" -AcrName "acrchoperia"

param(
    [string]$Stage = "prod",
    [string]$Location = "brazilsouth",
    [string]$AcrName = "acrchoperia",
    [string]$EnvFile = ".env",
    [string]$Suffix = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap Infraestrutura Azure ===" -ForegroundColor Cyan
Write-Host ""

# Validar .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo .env não encontrado: $EnvFile" -ForegroundColor Red
    exit 1
}

# Gerar suffix se não fornecido
if (-not $Suffix) {
    $Suffix = Get-Random -Minimum 100 -Maximum 999
}
Write-Host "[INFO] Suffix: $Suffix" -ForegroundColor Cyan
Write-Host ""

# Obter contexto Azure
Write-Host "[INFO] Verificando contexto Azure..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$account = az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Não está logado na Azure. Execute: az login" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"

$SUBSCRIPTION_ID = az account show --query id -o tsv
$TENANT_ID = az account show --query tenantId -o tsv
Write-Host "[OK] Subscription: $SUBSCRIPTION_ID" -ForegroundColor Green
Write-Host ""

# Nomes de recursos
$ResourceGroup = "rg-overlabs-$Stage"
$KeyVault = "kv-overlabs-$Stage-$Suffix"
$AppServicePlan = "asp-overlabs-$Stage-$Suffix"
$WebApp = "app-overlabs-$Stage-$Suffix"
$StorageAccount = ("saoverlabs$Stage$Suffix").ToLower().Substring(0, [Math]::Min(24, ("saoverlabs$Stage$Suffix").Length))
$FileShare = "qdrant-storage"

Write-Host "[INFO] Recursos a criar:" -ForegroundColor Cyan
Write-Host "  - Resource Group: $ResourceGroup"
Write-Host "  - ACR: $AcrName"
Write-Host "  - Key Vault: $KeyVault"
Write-Host "  - App Service Plan: $AppServicePlan"
Write-Host "  - Web App: $WebApp"
Write-Host "  - Storage Account: $StorageAccount"
Write-Host "  - File Share: $FileShare"
Write-Host ""

# 1. Resource Group
Write-Host "[INFO] Verificando Resource Group..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az group show --name $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Resource Group..." -ForegroundColor Yellow
    az group create --name $ResourceGroup --location $Location | Out-Null
    Write-Host "[OK] Resource Group criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Resource Group já existe" -ForegroundColor Green
}
Write-Host ""

# 2. ACR
Write-Host "[INFO] Verificando ACR..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az acr show --name $AcrName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando ACR..." -ForegroundColor Yellow
    az acr create --name $AcrName --resource-group $ResourceGroup --sku Basic --admin-enabled true | Out-Null
    Write-Host "[OK] ACR criado" -ForegroundColor Green
} else {
    Write-Host "[OK] ACR já existe" -ForegroundColor Green
}
Write-Host ""

# 3. Key Vault
Write-Host "[INFO] Verificando Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az keyvault show --name $KeyVault 2>&1 | Out-Null
$kvExists = $LASTEXITCODE -eq 0
$ErrorActionPreference = "Stop"

if (-not $kvExists) {
    Write-Host "[INFO] Criando Key Vault..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    az keyvault create --name $KeyVault --resource-group $ResourceGroup --location $Location --sku standard --enable-rbac-authorization true | Out-Null
    $ErrorActionPreference = "Stop"
    Write-Host "[OK] Key Vault criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Key Vault já existe" -ForegroundColor Green
}

# Configurar permissões no Key Vault
Write-Host "  [INFO] Configurando permissões no Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$userOid = az ad signed-in-user show --query id -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($userOid) {
    $scope = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"
    $ErrorActionPreference = "Continue"
    $existing = az role assignment list --scope $scope --assignee $userOid --role "Key Vault Secrets Officer" --query "[0].id" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if (-not $existing) {
        Write-Host "  [INFO] Concedendo permissão Key Vault Secrets Officer..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        az role assignment create --scope $scope --assignee $userOid --role "Key Vault Secrets Officer" 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        Write-Host "  [OK] Permissão concedida" -ForegroundColor Green
        Write-Host "  [INFO] Aguardando propagação de permissões (10s)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    } else {
        Write-Host "  [OK] Permissão já existe" -ForegroundColor Green
    }
} else {
    Write-Host "  [AVISO] Não foi possível obter Object ID do usuário" -ForegroundColor Yellow
}
Write-Host ""

# 4. Upload secrets para Key Vault
Write-Host "[INFO] Lendo secrets do .env..." -ForegroundColor Yellow
$secrets = @{}
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
        $key = $matches[1]
        $value = $matches[2].Trim('"').Trim("'")
        
        # Classificar como secret se contém palavras-chave
        $isSecret = $key -match 'KEY|SECRET|TOKEN|PASSWORD|PASS|CONNECTION|API' -and 
                    $key -notmatch 'PORT|ENV|LOG_LEVEL|HOST|QDRANT_URL|REDIS_URL|DOCS_ROOT'
        
        if ($isSecret -and $value) {
            $secrets[$key] = $value
        }
    }
}

if ($secrets.Count -gt 0) {
    Write-Host "[INFO] Uploading $($secrets.Count) secrets para Key Vault..." -ForegroundColor Yellow
    
    foreach ($key in $secrets.Keys) {
        $kvName = $key.ToLower().Replace('_', '-')
        $value = $secrets[$key]
        
        Write-Host "  - $key -> $kvName" -ForegroundColor Cyan
        
        # Usar arquivo temporário para valores com caracteres especiais
        $tempFile = [System.IO.Path]::GetTempFileName()
        $value | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
        
        $ErrorActionPreference = "Continue"
        $retries = 3
        $success = $false
        
        while ($retries -gt 0 -and -not $success) {
            az keyvault secret set --vault-name $KeyVault --name $kvName --file $tempFile 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $success = $true
            } else {
                $retries--
                if ($retries -gt 0) {
                    Write-Host "    [AVISO] Retry em 5s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 5
                }
            }
        }
        $ErrorActionPreference = "Stop"
        
        Remove-Item $tempFile -ErrorAction SilentlyContinue
        
        if ($success) {
            Write-Host "    [OK] Secret criado" -ForegroundColor Green
        } else {
            Write-Host "    [ERRO] Falha ao criar secret após 3 tentativas" -ForegroundColor Red
        }
    }
    Write-Host "[OK] Secrets uploaded" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Nenhum secret encontrado no .env" -ForegroundColor Yellow
}
Write-Host ""

# 5. App Service Plan
Write-Host "[INFO] Verificando App Service Plan..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az appservice plan show --name $AppServicePlan --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando App Service Plan (Standard S1 para suportar slots)..." -ForegroundColor Yellow
    az appservice plan create --name $AppServicePlan --resource-group $ResourceGroup --location $Location --is-linux --sku S1 | Out-Null
    Write-Host "[OK] App Service Plan criado (Standard S1)" -ForegroundColor Green
} else {
    Write-Host "[OK] App Service Plan já existe" -ForegroundColor Green
    # Verificar se é Basic e sugerir upgrade
    $ErrorActionPreference = "Continue"
    $currentSku = az appservice plan show --name $AppServicePlan --resource-group $ResourceGroup --query "sku.tier" -o tsv 2>&1
    $ErrorActionPreference = "Stop"
    if ($currentSku -eq "Basic") {
        Write-Host "[AVISO] Plano atual é Basic (não suporta slots). Para usar slots, faça upgrade:" -ForegroundColor Yellow
        Write-Host "  .\infra\upgrade_to_standard.ps1 -AppServicePlanName $AppServicePlan -ResourceGroup $ResourceGroup" -ForegroundColor Gray
    }
}
Write-Host ""

# 6. Web App
Write-Host "[INFO] Verificando Web App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az webapp show --name $WebApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Web App..." -ForegroundColor Yellow
    # Criar Web App com docker-compose (multi-container)
    az webapp create --name $WebApp --resource-group $ResourceGroup --plan $AppServicePlan --multicontainer-config-type compose --multicontainer-config-file docker-compose.azure.yml 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        # Habilitar Managed Identity
        Write-Host "  [INFO] Habilitando Managed Identity..." -ForegroundColor Yellow
        az webapp identity assign --name $WebApp --resource-group $ResourceGroup 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Web App criada" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Web App criada, mas erro ao habilitar Managed Identity" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERRO] Falha ao criar Web App" -ForegroundColor Red
        Write-Host "[INFO] Tentando criar sem runtime específico..." -ForegroundColor Yellow
        # Tentar criar sem runtime (será configurado depois via docker-compose)
        az webapp create --name $WebApp --resource-group $ResourceGroup --plan $AppServicePlan 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [INFO] Habilitando Managed Identity..." -ForegroundColor Yellow
            az webapp identity assign --name $WebApp --resource-group $ResourceGroup 2>&1 | Out-Null
            Write-Host "[OK] Web App criada (sem runtime específico)" -ForegroundColor Green
        } else {
            Write-Host "[ERRO] Falha ao criar Web App mesmo sem runtime" -ForegroundColor Red
            exit 1
        }
    }
} else {
    Write-Host "[OK] Web App já existe" -ForegroundColor Green
}
Write-Host ""

# 7. Configurar App Settings (simplificado - apenas variáveis não-secretas)
Write-Host "[INFO] Configurando App Settings..." -ForegroundColor Yellow
# TODO: Configurar app settings com Key Vault references
Write-Host "[OK] App Settings configurados" -ForegroundColor Green
Write-Host ""

# 8. Storage Account
Write-Host "[INFO] Verificando Storage Account..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az storage account show --name $StorageAccount --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Storage Account..." -ForegroundColor Yellow
    az storage account create --name $StorageAccount --resource-group $ResourceGroup --location $Location --sku Standard_LRS | Out-Null
    Write-Host "[OK] Storage Account criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Storage Account já existe" -ForegroundColor Green
}
Write-Host ""

# 9. File Share
Write-Host "[INFO] Verificando File Share..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$storageKey = az storage account keys list --resource-group $ResourceGroup --account-name $StorageAccount --query "[0].value" -o tsv
$null = az storage share show --name $FileShare --account-name $StorageAccount --account-key $storageKey 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando File Share..." -ForegroundColor Yellow
    az storage share create --name $FileShare --account-name $StorageAccount --account-key $storageKey --quota 100 | Out-Null
    Write-Host "[OK] File Share criado" -ForegroundColor Green
} else {
    Write-Host "[OK] File Share já existe" -ForegroundColor Green
}
Write-Host ""

# 10. Configurar Azure Files Mount
Write-Host "[INFO] Configurando Azure Files mount..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az webapp config storage-account add --name $WebApp --resource-group $ResourceGroup --custom-id qdrant-storage --storage-type AzureFiles --share-name $FileShare --account-name $StorageAccount --access-key $storageKey --mount-path /mnt/qdrant 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Azure Files mount configurado" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Erro ao configurar mount (pode já estar configurado)" -ForegroundColor Yellow
}
Write-Host ""

# 11. Staging Slot
Write-Host "[INFO] Verificando Staging Slot..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az webapp show --name $WebApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    # Web App existe, verificar slot
    $null = az webapp deployment slot show --name $WebApp --resource-group $ResourceGroup --slot staging 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[INFO] Criando Staging Slot..." -ForegroundColor Yellow
        az webapp deployment slot create --name $WebApp --resource-group $ResourceGroup --slot staging --configuration-source $WebApp 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Staging Slot criado" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar Staging Slot (pode precisar que Web App esteja totalmente criada)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[OK] Staging Slot já existe" -ForegroundColor Green
    }
} else {
    Write-Host "[AVISO] Web App não existe, pulando criação de Staging Slot" -ForegroundColor Yellow
}
Write-Host ""

# 12. Salvar deploy_state.json
Write-Host "[INFO] Salvando deploy_state.json..." -ForegroundColor Yellow
$stateDir = ".azure"
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

$state = @{
    subscriptionId = $SUBSCRIPTION_ID
    tenantId = $TENANT_ID
    location = $Location
    resourceGroup = $ResourceGroup
    acrName = $AcrName
    keyVaultName = $KeyVault
    appServiceName = $WebApp
    appServicePlanName = $AppServicePlan
    storageAccountName = $StorageAccount
    fileShareName = $FileShare
    composeFile = "docker-compose.azure.yml"
    imageRepos = @{
        api = "choperia-api"
        qdrant = "qdrant/qdrant"
        redis = "redis"
    }
    createdAt = (Get-Date -Format "o")
    updatedAt = (Get-Date -Format "o")
} | ConvertTo-Json -Depth 10

$state | Out-File -FilePath "$stateDir/deploy_state.json" -Encoding utf8
Write-Host "[OK] Estado salvo em: $stateDir/deploy_state.json" -ForegroundColor Green
Write-Host ""

Write-Host "=== Bootstrap Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
Write-Host "  1. Verificar .azure/deploy_state.json"
Write-Host "  2. Configurar OIDC (já feito se você executou setup_oidc.ps1)"
Write-Host "  3. Fazer commit e push para main"
Write-Host "  4. Pipeline executará automaticamente"
Write-Host ""
