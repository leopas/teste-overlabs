# Script para configurar OIDC (Federated Credentials) no Azure AD
# Uso: .\infra\setup_oidc.ps1 -GitHubOrg "seu-org" -GitHubRepo "teste-overlabs"

param(
    [Parameter(Mandatory=$true)]
    [string]$GitHubOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$GitHubRepo,
    
    [string]$AppName = "github-actions-rag-overlabs",
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$AcrName = "acrchoperia",
    [string]$Location = "brazilsouth"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Configuração OIDC para GitHub Actions ===" -ForegroundColor Cyan
Write-Host ""

# Verificar se está logado
Write-Host "[INFO] Verificando login Azure..." -ForegroundColor Yellow
$account = az account show 2>$null
if (-not $account) {
    Write-Host "[ERRO] Não está logado na Azure. Execute: az login" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Logado na Azure" -ForegroundColor Green
Write-Host ""

# Obter Subscription ID
$SUBSCRIPTION_ID = az account show --query id -o tsv
Write-Host "[INFO] Subscription ID: $SUBSCRIPTION_ID" -ForegroundColor Cyan
Write-Host ""

# Verificar se App Registration já existe
Write-Host "[INFO] Verificando App Registration: $AppName..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$existingApp = az ad app list --display-name $AppName --query "[0].appId" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($existingApp) {
    Write-Host "[OK] App Registration já existe (reutilizando)" -ForegroundColor Green
    $APP_ID = $existingApp
} else {
    Write-Host "[INFO] Criando App Registration..." -ForegroundColor Yellow
    $APP_ID = az ad app create --display-name $AppName --query appId -o tsv
    if (-not $APP_ID) {
        Write-Host "[ERRO] Falha ao criar App Registration" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] App Registration criado" -ForegroundColor Green
}
Write-Host "   App ID (CLIENT_ID): $APP_ID" -ForegroundColor Cyan
Write-Host "   (Salve este valor para usar no GitHub Secrets!)" -ForegroundColor Yellow
Write-Host ""

# Verificar se Service Principal já existe
Write-Host "[INFO] Verificando Service Principal..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$existingSP = az ad sp show --id $APP_ID --query id -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($existingSP) {
    Write-Host "[OK] Service Principal já existe (reutilizando)" -ForegroundColor Green
    $SP_ID = $existingSP
} else {
    Write-Host "[INFO] Criando Service Principal..." -ForegroundColor Yellow
    $SP_ID = az ad sp create --id $APP_ID --query id -o tsv
    if (-not $SP_ID) {
        Write-Host "[ERRO] Falha ao criar Service Principal" -ForegroundColor Red
        Write-Host "   Tente deletar o App Registration existente e executar novamente:" -ForegroundColor Yellow
        Write-Host "   az ad app delete --id $APP_ID" -ForegroundColor Gray
        exit 1
    }
    Write-Host "[OK] Service Principal criado" -ForegroundColor Green
}
Write-Host "   SP ID: $SP_ID" -ForegroundColor Cyan
Write-Host ""

# Verificar se Resource Group existe, criar se não existir
Write-Host "[INFO] Verificando Resource Group..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az group show --name $ResourceGroup 2>&1 | Out-Null
$rgExists = $LASTEXITCODE -eq 0
$ErrorActionPreference = "Stop"

if (-not $rgExists) {
    Write-Host "[INFO] Resource Group não existe. Criando..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $null = az group create --name $ResourceGroup --location $Location 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Resource Group criado: $ResourceGroup em $Location" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao criar Resource Group" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Resource Group já existe: $ResourceGroup" -ForegroundColor Green
}
Write-Host ""

# Verificar e dar permissões (Contributor no Resource Group)
Write-Host "[INFO] Verificando permissão Contributor no Resource Group..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$contributorExists = az role assignment list `
  --assignee $SP_ID `
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ResourceGroup" `
  --role "Contributor" `
  --query "[0].id" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($contributorExists) {
    Write-Host "[OK] Permissão Contributor já existe (reutilizando)" -ForegroundColor Green
} else {
    Write-Host "[INFO] Concedendo permissão Contributor..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    az role assignment create `
      --role "Contributor" `
      --assignee $SP_ID `
      --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ResourceGroup" 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Permissão Contributor concedida" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Erro ao conceder permissão Contributor (pode já existir)" -ForegroundColor Yellow
    }
}
Write-Host ""

# Verificar se ACR existe antes de dar permissão
Write-Host "[INFO] Verificando ACR..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$acrOutput = az acr show --name $AcrName 2>&1 | Out-String
$acrExists = ($LASTEXITCODE -eq 0) -and ($acrOutput -notmatch "ResourceNotFound" -and $acrOutput -notmatch "was not found")
$ErrorActionPreference = "Stop"

if ($acrExists) {
    Write-Host "[OK] ACR encontrado: $AcrName" -ForegroundColor Green
    # Obter o Resource Group real do ACR
    $ErrorActionPreference = "Continue"
    $acrRG = az acr show --name $AcrName --query resourceGroup -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($acrRG) {
        Write-Host "[INFO] ACR está no Resource Group: $acrRG" -ForegroundColor Cyan
        $acrScope = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$acrRG/providers/Microsoft.ContainerRegistry/registries/$AcrName"
    } else {
        # Fallback: usar o Resource Group especificado
        $acrScope = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$AcrName"
    }
    $ErrorActionPreference = "Continue"
    $acrPushExists = az role assignment list `
      --assignee $SP_ID `
      --scope $acrScope `
      --role "AcrPush" `
      --query "[0].id" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($acrPushExists) {
        Write-Host "[OK] Permissão AcrPush já existe (reutilizando)" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Concedendo permissão AcrPush no ACR..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        $acrError = az role assignment create `
          --role "AcrPush" `
          --assignee $SP_ID `
          --scope $acrScope 2>&1 | Out-String
        $ErrorActionPreference = "Stop"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Permissão AcrPush concedida" -ForegroundColor Green
        } else {
            if ($acrError -match "already exists" -or $acrError -match "RoleAssignmentExists") {
                Write-Host "[OK] Permissão AcrPush já existe (reutilizando)" -ForegroundColor Green
            } else {
                Write-Host "[AVISO] Erro ao conceder permissão AcrPush" -ForegroundColor Yellow
                Write-Host "   Detalhes: $($acrError.Trim())" -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Host "[AVISO] ACR '$AcrName' não existe ainda." -ForegroundColor Yellow
    Write-Host "   A permissão AcrPush será configurada quando o ACR for criado pelo bootstrap." -ForegroundColor Yellow
    Write-Host "   Ou execute manualmente após criar o ACR:" -ForegroundColor Yellow
    Write-Host "   az role assignment create --role AcrPush --assignee $SP_ID --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$AcrName" -ForegroundColor Gray
}
Write-Host ""

# Verificar e criar federated credential para branch main
Write-Host "[INFO] Verificando federated credential para branch main..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$mainCredExists = az ad app federated-credential list --id $APP_ID --query "[?name=='github-actions-main']" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($mainCredExists) {
    Write-Host "[OK] Federated credential para main já existe (reutilizando)" -ForegroundColor Green
} else {
    Write-Host "[INFO] Criando federated credential para branch main..." -ForegroundColor Yellow
    $mainParams = @{
        name = "github-actions-main"
        issuer = "https://token.actions.githubusercontent.com"
        subject = "repo:$GitHubOrg/$GitHubRepo`:ref:refs/heads/main"
        audiences = @("api://AzureADTokenExchange")
    }
    
    # Usar arquivo temporário para evitar problemas de parsing no PowerShell
    $tempJsonFile = [System.IO.Path]::GetTempFileName()
    $mainParams | ConvertTo-Json -Compress | Out-File -FilePath $tempJsonFile -Encoding utf8 -NoNewline

    $ErrorActionPreference = "Continue"
    $mainError = az ad app federated-credential create `
      --id $APP_ID `
      --parameters "@$tempJsonFile" 2>&1 | Out-String
    $ErrorActionPreference = "Stop"
    
    # Limpar arquivo temporário
    Remove-Item $tempJsonFile -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Federated credential para main criada" -ForegroundColor Green
    } else {
        if ($mainError -match "already exists" -or $mainError -match "Conflict") {
            Write-Host "[OK] Federated credential para main já existe (reutilizando)" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar federated credential para main" -ForegroundColor Yellow
            Write-Host "   Detalhes: $($mainError.Trim())" -ForegroundColor Gray
        }
    }
}
Write-Host ""

# Verificar e criar federated credential para tags
Write-Host "[INFO] Verificando federated credential para tags..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$tagsCredExists = az ad app federated-credential list --id $APP_ID --query "[?name=='github-actions-tags']" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($tagsCredExists) {
    Write-Host "[OK] Federated credential para tags já existe (reutilizando)" -ForegroundColor Green
} else {
    Write-Host "[INFO] Criando federated credential para tags..." -ForegroundColor Yellow
    $tagsParams = @{
        name = "github-actions-tags"
        issuer = "https://token.actions.githubusercontent.com"
        subject = "repo:$GitHubOrg/$GitHubRepo`:ref:refs/tags/*"
        audiences = @("api://AzureADTokenExchange")
    }
    
    # Usar arquivo temporário para evitar problemas de parsing no PowerShell
    $tempJsonFile = [System.IO.Path]::GetTempFileName()
    $tagsParams | ConvertTo-Json -Compress | Out-File -FilePath $tempJsonFile -Encoding utf8 -NoNewline

    $ErrorActionPreference = "Continue"
    $tagsError = az ad app federated-credential create `
      --id $APP_ID `
      --parameters "@$tempJsonFile" 2>&1 | Out-String
    $ErrorActionPreference = "Stop"
    
    # Limpar arquivo temporário
    Remove-Item $tempJsonFile -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Federated credential para tags criada" -ForegroundColor Green
    } else {
        if ($tagsError -match "already exists" -or $tagsError -match "Conflict") {
            Write-Host "[OK] Federated credential para tags já existe (reutilizando)" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar federated credential para tags" -ForegroundColor Yellow
            Write-Host "   Detalhes: $($tagsError.Trim())" -ForegroundColor Gray
        }
    }
}
Write-Host ""

# Obter Tenant ID
Write-Host "[INFO] Obtendo Tenant ID..." -ForegroundColor Yellow
$TENANT_ID = az account show --query tenantId -o tsv
if (-not $TENANT_ID) {
    Write-Host "[ERRO] Não foi possível obter Tenant ID" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Configuração Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Agora configure os seguintes secrets no GitHub:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Vá para: https://github.com/$GitHubOrg/$GitHubRepo/settings/secrets/actions" -ForegroundColor Yellow
Write-Host ""
Write-Host "2. Adicione os seguintes secrets:" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Name: AZURE_CLIENT_ID" -ForegroundColor White
Write-Host "   Value: $APP_ID" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Name: AZURE_TENANT_ID" -ForegroundColor White
Write-Host "   Value: $TENANT_ID" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Name: AZURE_SUBSCRIPTION_ID" -ForegroundColor White
Write-Host "   Value: $SUBSCRIPTION_ID" -ForegroundColor Cyan
Write-Host ""
Write-Host "3. Após adicionar, faça commit e push para main" -ForegroundColor Cyan
Write-Host "   A pipeline executará automaticamente!" -ForegroundColor Cyan
Write-Host ""
Write-Host "=== Resumo dos Valores ===" -ForegroundColor Green
Write-Host "AZURE_CLIENT_ID=$APP_ID" -ForegroundColor White
Write-Host "AZURE_TENANT_ID=$TENANT_ID" -ForegroundColor White
Write-Host "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID" -ForegroundColor White
Write-Host ""
