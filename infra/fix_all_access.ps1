# Script para corrigir todos os problemas de acesso encontrados na auditoria
# Resolve: Key Vault permissions, Storage permissions, Volume mount, Secrets

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$KeyVaultName = $null,
    [string]$Environment = $null,
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Correção de Acessos e Permissões ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $KeyVaultName -or -not $Environment) {
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
    if (-not $KeyVaultName) {
        $KeyVaultName = $state.keyVaultName
    }
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVaultName" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host ""

# 1. Managed Identity
Write-Host "[1/5] Verificando Managed Identity..." -ForegroundColor Yellow
$identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if (-not $identity -or -not $identity.type -or $identity.type -ne "SystemAssigned") {
    Write-Host "  [INFO] Habilitando Managed Identity..." -ForegroundColor Cyan
    az containerapp identity assign `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --system-assigned | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Managed Identity habilitada" -ForegroundColor Green
        Start-Sleep -Seconds 5
        $identity = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json
    } else {
        Write-Host "  [ERRO] Falha ao habilitar Managed Identity" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  [OK] Managed Identity já está habilitada" -ForegroundColor Green
}

$principalId = $identity.principalId
Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
Write-Host ""

# 2. Criar secrets no Key Vault
Write-Host "[2/5] Verificando/criando secrets no Key Vault..." -ForegroundColor Yellow
if (Test-Path $EnvFile) {
    # Carregar secrets do .env
    $secrets = @{}
    $denylist = @(
        "PORT", "ENV", "LOG_LEVEL", "HOST",
        "QDRANT_URL", "REDIS_URL", "DOCS_ROOT",
        "MYSQL_PORT", "MYSQL_HOST", "MYSQL_DATABASE", "MYSQL_SSL_CA",
        "OTEL_ENABLED", "USE_OPENAI_EMBEDDINGS",
        "AUDIT_LOG_ENABLED", "AUDIT_LOG_INCLUDE_TEXT", "AUDIT_LOG_RAW_MODE", "AUDIT_LOG_REDACT", "AUDIT_LOG_RAW_MAX_CHARS",
        "ABUSE_CLASSIFIER_ENABLED", "ABUSE_RISK_THRESHOLD",
        "PROMPT_FIREWALL_ENABLED", "PROMPT_FIREWALL_RULES_PATH", "PROMPT_FIREWALL_MAX_RULES", "PROMPT_FIREWALL_RELOAD_CHECK_SECONDS",
        "PIPELINE_LOG_ENABLED", "PIPELINE_LOG_INCLUDE_TEXT",
        "TRACE_SINK", "TRACE_SINK_QUEUE_SIZE",
        "AUDIT_ENC_AAD_MODE",
        "RATE_LIMIT_PER_MINUTE", "CACHE_TTL_SECONDS",
        "FIREWALL_LOG_SAMPLE_RATE",
        "OPENAI_MODEL", "OPENAI_MODEL_ENRICHMENT", "OPENAI_EMBEDDINGS_MODEL",
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "DOCS_HOST_PATH",
        "API_PORT", "QDRANT_PORT", "REDIS_PORT"
    )
    $secretKeywords = @("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CONNECTION", "API")
    
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            $key = $matches[1]
            $value = $matches[2].Trim('"').Trim("'")
            
            if ($value -match '^(.+?)\s*#') {
                $value = $matches[1].Trim()
            }
            
            if ($value) {
                $isInDenylist = $denylist -contains $key
                $keyUpper = $key.ToUpper()
                $hasSecretKeyword = $false
                foreach ($keyword in $secretKeywords) {
                    if ($keyUpper -like "*$keyword*") {
                        $hasSecretKeyword = $true
                        break
                    }
                }
                
                $isSecret = -not $isInDenylist -and $hasSecretKeyword
                
                if ($isSecret) {
                    $secrets[$key] = $value
                }
            }
        }
    }
    
    foreach ($key in $secrets.Keys) {
        $kvName = $key.ToLower().Replace('_', '-')
        $value = $secrets[$key]
        
        $ErrorActionPreference = "Continue"
        $secretExists = az keyvault secret show --vault-name $KeyVaultName --name $kvName --query "name" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($secretExists) {
            Write-Host "  [OK] Secret '$kvName' já existe" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Criando secret '$kvName'..." -ForegroundColor Cyan
            
            # Verificar permissões do usuário atual no Key Vault
            $ErrorActionPreference = "Continue"
            $currentUser = az account show --query user.name -o tsv 2>$null
            $kvPermissions = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.accessPolicies[?objectId=='$(az ad signed-in-user show --query id -o tsv)']" -o json 2>$null
            $kvRbacEnabled = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
            $ErrorActionPreference = "Stop"
            
            if ($kvRbacEnabled -eq $true) {
                Write-Host "    [INFO] Key Vault usa RBAC. Verificando suas permissões..." -ForegroundColor Gray
                $subscriptionId = az account show --query id -o tsv
                $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
                $userObjectId = az ad signed-in-user show --query id -o tsv
                
                $ErrorActionPreference = "Continue"
                $userRoles = az role assignment list --scope $kvResourceId --assignee $userObjectId --query "[].roleDefinitionName" -o tsv 2>$null
                $ErrorActionPreference = "Stop"
                
                if ($userRoles) {
                    Write-Host "    [INFO] Suas permissões RBAC: $($userRoles -join ', ')" -ForegroundColor Gray
                    $hasSecretOps = $userRoles | Where-Object { $_ -like "*Key Vault Secrets Officer*" -or $_ -like "*Key Vault Secrets User*" -or $_ -like "*Contributor*" -or $_ -like "*Owner*" }
                    if (-not $hasSecretOps) {
                        Write-Host "    [ERRO] Você não tem permissão para criar secrets!" -ForegroundColor Red
                        Write-Host "    [INFO] Peça a um administrador para conceder a role 'Key Vault Secrets Officer' ou 'Owner'" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "    [ERRO] Você não tem permissões RBAC no Key Vault!" -ForegroundColor Red
                    Write-Host "    [INFO] Peça a um administrador para conceder a role 'Key Vault Secrets Officer' ou 'Owner'" -ForegroundColor Yellow
                }
            }
            
            # Tentar criar o secret usando arquivo temporário (mais confiável)
            $tempFile = [System.IO.Path]::GetTempFileName()
            $createSuccess = $false
            $errorDetails = @()
            
            try {
                # Usar UTF8 sem BOM para evitar problemas
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($tempFile, $value, $utf8NoBom)
                
                # Tentar criar o secret
                $ErrorActionPreference = "Continue"
                $createOutput = az keyvault secret set --vault-name $KeyVaultName --name $kvName --file $tempFile 2>&1
                $createExitCode = $LASTEXITCODE
                $ErrorActionPreference = "Stop"
                
                if ($createExitCode -eq 0) {
                    $createSuccess = $true
                } else {
                    # Capturar erro
                    if ($createOutput) {
                        if ($createOutput -is [System.Array]) {
                            $errorDetails = $createOutput
                        } else {
                            $errorDetails = @($createOutput.ToString())
                        }
                    }
                    
                    # Se falhar com arquivo, tentar com --value diretamente
                    Write-Host "    [INFO] Tentando método alternativo (--value)..." -ForegroundColor Gray
                    $ErrorActionPreference = "Continue"
                    
                    # Tentar com --value (escapar aspas)
                    $valueForCmd = $value -replace '"', '\"'
                    $createOutput2 = az keyvault secret set --vault-name $KeyVaultName --name $kvName --value "$valueForCmd" 2>&1
                    $createExitCode2 = $LASTEXITCODE
                    $ErrorActionPreference = "Stop"
                    
                    if ($createExitCode2 -eq 0) {
                        $createSuccess = $true
                    } else {
                        # Capturar segundo erro
                        if ($createOutput2) {
                            if ($createOutput2 -is [System.Array]) {
                                $errorDetails = $createOutput2
                            } else {
                                $errorDetails = @($createOutput2.ToString())
                            }
                        }
                    }
                }
            } catch {
                $errorDetails = @($_.Exception.Message)
            } finally {
                if (Test-Path $tempFile) {
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
            
            if ($createSuccess) {
                Write-Host "  [OK] Secret '$kvName' criado" -ForegroundColor Green
            } else {
                Write-Host "  [ERRO] Falha ao criar secret '$kvName'" -ForegroundColor Red
                
                # Mostrar erro de forma mais clara
                if ($errorDetails.Count -gt 0) {
                    Write-Host "    Detalhes do erro:" -ForegroundColor Yellow
                    $errorDetails | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -First 5 | ForEach-Object {
                        $errorLine = $_.ToString().Trim()
                        if ($errorLine -notmatch "WARNING|INFO|Connecting|Successfully|Disconnecting|received|Use ctrl") {
                            Write-Host "      $errorLine" -ForegroundColor Red
                        }
                    }
                }
                
                Write-Host ""
                Write-Host "    [INFO] Possíveis causas:" -ForegroundColor Yellow
                Write-Host "      1. Você não tem permissão para criar secrets no Key Vault" -ForegroundColor Gray
                Write-Host "      2. Key Vault está bloqueado ou desabilitado" -ForegroundColor Gray
                Write-Host "      3. Nome do secret é inválido (caracteres especiais)" -ForegroundColor Gray
                Write-Host ""
                Write-Host "    [INFO] Execute para verificar permissões:" -ForegroundColor Cyan
                Write-Host "      .\infra\fix_keyvault_user_permissions.ps1" -ForegroundColor Gray
                Write-Host ""
                Write-Host "    [INFO] Ou tente criar manualmente:" -ForegroundColor Cyan
                Write-Host "      az keyvault secret set --vault-name $KeyVaultName --name '$kvName' --value 'SEU_VALOR_AQUI'" -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Host "  [AVISO] Arquivo .env não encontrado" -ForegroundColor Yellow
}
Write-Host ""

# 3. Permissões RBAC no Key Vault
Write-Host "[3/5] Verificando permissões RBAC no Key Vault..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$kvRbacEnabled = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if ($kvRbacEnabled -eq $true) {
    $subscriptionId = az account show --query id -o tsv
    $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
    $requiredRole = "Key Vault Secrets User"
    
    $ErrorActionPreference = "Continue"
    $rbacRoles = az role assignment list --scope $kvResourceId --assignee $principalId --query "[].roleDefinitionName" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    $hasSecretsUser = $rbacRoles | Where-Object { $_ -like "*Key Vault Secrets User*" -or $_ -like "*Secrets User*" }
    
    if (-not $hasSecretsUser) {
        Write-Host "  [INFO] Concedendo permissão '$requiredRole'..." -ForegroundColor Cyan
        $ErrorActionPreference = "Continue"
        az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role $requiredRole `
            --scope $kvResourceId 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Permissão '$requiredRole' concedida" -ForegroundColor Green
        } else {
            Write-Host "  [AVISO] Pode já ter permissão ou erro ao conceder" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK] Permissão '$requiredRole' já existe" -ForegroundColor Green
    }
} else {
    Write-Host "  [AVISO] Key Vault não usa RBAC (usa Access Policies)" -ForegroundColor Yellow
}
Write-Host ""

# 4. Permissões no Storage Account
Write-Host "[4/5] Verificando permissões no Storage Account..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{accountName:properties.azureFile.accountName}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if ($volumeInfo) {
    $volumeObj = $volumeInfo | ConvertFrom-Json
    $storageAccount = $volumeObj.accountName
    
    $storageAccountId = az storage account show --name $storageAccount --resource-group $ResourceGroup --query id -o tsv
    $requiredRole = "Storage File Data SMB Share Contributor"
    
    $ErrorActionPreference = "Continue"
    $roleAssignments = az role assignment list `
        --assignee $principalId `
        --scope $storageAccountId `
        --query "[?roleDefinitionName=='$requiredRole']" -o json 2>$null
    $ErrorActionPreference = "Stop"
    
    if (-not $roleAssignments -or ($roleAssignments | ConvertFrom-Json).Count -eq 0) {
        Write-Host "  [INFO] Concedendo permissão '$requiredRole'..." -ForegroundColor Cyan
        $ErrorActionPreference = "Continue"
        az role assignment create `
            --assignee $principalId `
            --role $requiredRole `
            --scope $storageAccountId 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Permissão '$requiredRole' concedida" -ForegroundColor Green
            Start-Sleep -Seconds 5
        } else {
            Write-Host "  [AVISO] Pode já ter permissão ou erro ao conceder" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK] Permissão '$requiredRole' já existe" -ForegroundColor Green
    }
} else {
    Write-Host "  [ERRO] Volume 'documents-storage' não encontrado no Environment!" -ForegroundColor Red
    Write-Host "  [INFO] Execute: .\infra\bootstrap_container_apps.ps1 para criar o volume" -ForegroundColor Cyan
}
Write-Host ""

# 5. Volume mount no Container App
Write-Host "[5/5] Verificando volume mount no Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$currentVolumes = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json 2>$null | ConvertFrom-Json
$currentContainer = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

$hasVolume = $false
$hasVolumeMount = $false

if ($currentVolumes) {
    foreach ($vol in $currentVolumes) {
        if ($vol.name -eq "docs" -or $vol.name -eq "documents-storage") {
            $hasVolume = $true
            break
        }
    }
}

if ($currentContainer.volumeMounts) {
    foreach ($vm in $currentContainer.volumeMounts) {
        if ($vm.volumeName -eq "docs" -or $vm.volumeName -eq "documents-storage") {
            $hasVolumeMount = $true
            break
        }
    }
}

if (-not $hasVolume -or -not $hasVolumeMount) {
    Write-Host "  [INFO] Configurando volume mount..." -ForegroundColor Cyan
    Write-Host "  [INFO] Executando script de montagem de volume..." -ForegroundColor Yellow
    
    # Executar o script de montagem de volume
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) {
        $scriptDir = "infra"
    }
    $mountScript = Join-Path $scriptDir "mount_docs_volume.ps1"
    
    if (Test-Path $mountScript) {
        Write-Host "  [INFO] Executando: $mountScript" -ForegroundColor Gray
        & $mountScript -ResourceGroup $ResourceGroup -ApiAppName $ApiAppName -Environment $Environment
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Volume mount configurado" -ForegroundColor Green
        } else {
            Write-Host "  [AVISO] Falha ao configurar volume mount automaticamente" -ForegroundColor Yellow
            Write-Host "  [INFO] Execute manualmente: .\infra\mount_docs_volume.ps1" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  [AVISO] Script mount_docs_volume.ps1 nao encontrado em $mountScript" -ForegroundColor Yellow
        Write-Host "  [INFO] Execute manualmente: .\infra\mount_docs_volume.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host "  [OK] Volume mount ja esta configurado" -ForegroundColor Green
}
Write-Host ""

Write-Host "=== Correção Concluída ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Execute a auditoria novamente para verificar:" -ForegroundColor Cyan
Write-Host "  .\infra\audit_all_access.ps1" -ForegroundColor Gray
Write-Host ""
