# Script para criar/verificar API Container App com volume de documentos
# Uso: .\infra\bootstrap_api.ps1 -ResourceGroup "rg-overlabs-prod" -Environment "env-overlabs-prod-300" -ApiApp "app-overlabs-prod-300" -AcrName "acrchoperia" -KeyVault "kv-overlabs-prod-300" -QdrantUrl "http://app-overlabs-qdrant-prod-300:6333" -RedisUrl "redis://app-overlabs-redis-prod-300:6379/0" -EnvFile ".env"
#
# O script carrega automaticamente secrets e non-secrets do arquivo .env

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [Parameter(Mandatory=$true)]
    [string]$ApiApp,
    
    [Parameter(Mandatory=$true)]
    [string]$AcrName,
    
    [Parameter(Mandatory=$true)]
    [string]$KeyVault,
    
    [Parameter(Mandatory=$true)]
    [string]$QdrantUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$RedisUrl,
    
    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap API Container App ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiApp" -ForegroundColor Yellow
Write-Host "[INFO] ACR: $AcrName" -ForegroundColor Yellow
Write-Host "[INFO] Key Vault: $KeyVault" -ForegroundColor Yellow
Write-Host "[INFO] Env File: $EnvFile" -ForegroundColor Yellow
Write-Host ""

# Validar arquivo .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "[ERRO] Arquivo $EnvFile não encontrado" -ForegroundColor Red
    exit 1
}

# Carregar e classificar variáveis do .env
Write-Host "[INFO] Carregando variáveis do .env..." -ForegroundColor Cyan
$secrets = @{}
$nonSecrets = @{}

# Denylist: variáveis que NÃO são secrets mesmo contendo palavras-chave
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

# Palavras-chave que indicam secrets
$secretKeywords = @("KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "CONNECTION", "API")

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
        $key = $matches[1]
        $value = $matches[2].Trim('"').Trim("'")
        
        # Remover comentários inline
        if ($value -match '^(.+?)\s*#') {
            $value = $matches[1].Trim()
        }
        
        if ($value) {
            # Classificar como secret (mesma lógica do validate_env.py)
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
            } else {
                $nonSecrets[$key] = $value
            }
        }
    }
}

Write-Host "[INFO] Variáveis encontradas: $($secrets.Count + $nonSecrets.Count) total, $($secrets.Count) secrets, $($nonSecrets.Count) non-secrets" -ForegroundColor Cyan
Write-Host ""

# Construir env-vars (separar secrets de non-secrets)
# Para Container Apps, secrets devem ser criados com keyvaultref: e referenciados com secretref:
$envVars = @(
    "QDRANT_URL=$QdrantUrl",
    "REDIS_URL=$RedisUrl",
    "DOCS_ROOT=/app/DOC-IA"
)

# Adicionar todas as non-secrets do .env
foreach ($key in $nonSecrets.Keys) {
    $envVars += "$key=$($nonSecrets[$key])"
}

# Secrets serão adicionados separadamente usando --set-secrets com keyvaultref:
# e depois referenciados nas env vars com secretref:
$secretRefs = @{}
foreach ($key in $secrets.Keys) {
    $kvName = $key.ToLower().Replace('_', '-')
    # Nome do secret interno do Container App (usar o mesmo nome do Key Vault para simplicidade)
    $secretRefs[$key] = $kvName
}

# Verificar se já existe
Write-Host "[INFO] Verificando API Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $ApiApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando API Container App..." -ForegroundColor Yellow
    
    # Obter environment ID e location (sem capturar stderr)
    Write-Host "  [INFO] Obtendo Environment ID e location..." -ForegroundColor Cyan
    $ErrorActionPreference = "Continue"
    $envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv 2>$null
    $location = az containerapp env show --name $Environment --resource-group $ResourceGroup --query location -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    # Limpar e validar valores
    $envId = $envId.Trim()
    $location = $location.Trim()
    
    if (-not $envId -or $envId -match "error|not found") {
        Write-Host "  [ERRO] Falha ao obter Environment ID!" -ForegroundColor Red
        Write-Host "  [ERRO] Saída: $envId" -ForegroundColor Red
        Write-Host "  [AVISO] Tentando criar sem volume..." -ForegroundColor Yellow
        $useYaml = $false
    } else {
        Write-Host "  [OK] Environment ID obtido" -ForegroundColor Green
        if (-not $location -or $location -match "error|not found") {
            $location = "brazilsouth"  # Fallback padrão
        }
        # Garantir que location é código (não display name)
        $location = $location.ToLower().Replace(' ', '')
        Write-Host "  [OK] Location: $location" -ForegroundColor Green
        $useYaml = $true
    }
    
    # Obter credenciais ACR
    $acrLoginServer = az acr show --name $AcrName --query loginServer -o tsv
    $acrUsername = az acr credential show --name $AcrName --query username -o tsv
    $acrPassword = az acr credential show --name $AcrName --query passwords[0].value -o tsv
    
    # Criar Container App com volume usando YAML
    if ($useYaml) {
        Write-Host "  [INFO] Criando Container App com volume de documentos..." -ForegroundColor Cyan
        
        # IMPORTANTE: Criar app SEM secrets do Key Vault primeiro (chicken-and-egg)
        # A identity será criada junto com o app, depois concedemos permissão no KV,
        # e então atualizamos o app com os secrets do Key Vault
        
        # Construir lista de secrets (apenas ACR password por enquanto)
        $secretsYaml = ""
        $secretsYaml += "    - name: acr-password`n      value: $acrPassword`n"
        
        # NÃO adicionar secrets do Key Vault aqui - será feito depois de conceder permissão
        
        # Construir lista de env vars formatada (apenas non-secrets por enquanto)
        $envVarsYaml = ""
        foreach ($envVar in $envVars) {
            $parts = $envVar -split '=', 2
            $name = $parts[0]
            $value = $parts[1]
            
            # Valor normal: escapar aspas e caracteres especiais
            $value = $value -replace '\\', '\\\\'  # Escapar backslashes primeiro
            $value = $value -replace '"', '\"'      # Escapar aspas
            $value = $value -replace '`n', '\n'     # Escapar newlines
            $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
        }
        
        # NÃO adicionar env vars com secretRef aqui na criação inicial
        # Serão adicionadas depois de conceder permissão no Key Vault (chicken-and-egg)
        # Isso evita erro se a identity ainda não tem permissão no Key Vault
        
        # YAML no mesmo formato do Qdrant (que funcionou)
        # Adicionar location, aspas no envId, allowInsecure e traffic para evitar problemas de parsing
        $yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
  identity:
    type: SystemAssigned
  configuration:
    ingress:
      external: true
      allowInsecure: false
      targetPort: 8000
      transport: http
      traffic:
      - weight: 100
        latestRevision: true
    registries:
    - server: $acrLoginServer
      username: $acrUsername
      passwordSecretRef: acr-password
    secrets:
$secretsYaml
  template:
    containers:
    - name: api
      image: $acrLoginServer/choperia-api:latest
      env:
$envVarsYaml
      resources:
        cpu: 2.0
        memory: 4.0Gi
      volumeMounts:
      - volumeName: docs
        mountPath: /app/DOC-IA
    scale:
      minReplicas: 1
      maxReplicas: 5
    volumes:
    - name: docs
      storageType: AzureFile
      storageName: documents-storage
"@
        
        # YAML temporário em .azure/ (gitignored) para não commitar artefatos
        $azureDir = Join-Path (Split-Path $PSScriptRoot -Parent) ".azure"
        if (-not (Test-Path $azureDir)) { New-Item -ItemType Directory -Path $azureDir -Force | Out-Null }
        $tempYaml = Join-Path $azureDir "container-app-api-debug.yaml"
        # Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tempYaml, $yamlContent, $utf8NoBom)
        
        Write-Host "  [INFO] YAML gerado em: $tempYaml" -ForegroundColor Cyan
        
        $ErrorActionPreference = "Continue"
        try {
            $yamlOutput = az containerapp create `
                --name $ApiApp `
                --resource-group $ResourceGroup `
                --yaml $tempYaml 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Container App criado com volume" -ForegroundColor Green
                Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "  [ERRO] Falha ao criar com YAML (exit code: $LASTEXITCODE)" -ForegroundColor Red
                Write-Host "  [ERRO] Saída do comando:" -ForegroundColor Red
                $yamlOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                Write-Host "  [INFO] YAML mantido em: $tempYaml para inspeção" -ForegroundColor Cyan
                Write-Host "  [AVISO] Tentando criar sem volume..." -ForegroundColor Yellow
                # Fallback: criar sem volume usando CLI com sintaxe correta de Container Apps
                # Primeiro, construir comandos para secrets (keyvaultref) e env vars (secretref)
                $setSecretsArgs = @()
                $setSecretsArgs += "acr-password=$acrPassword"
                foreach ($key in $secrets.Keys) {
                    $kvName = $key.ToLower().Replace('_', '-')
                    $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName"
                    $setSecretsArgs += "$kvName=keyvaultref:$secretUri"
                }
                
                $setEnvVarsArgs = @()
                foreach ($envVar in $envVars) {
                    $setEnvVarsArgs += $envVar
                }
                foreach ($key in $secretRefs.Keys) {
                    $secretName = $secretRefs[$key]
                    $setEnvVarsArgs += "$key=secretref:$secretName"
                }
                
                az containerapp create `
                    --name $ApiApp `
                    --resource-group $ResourceGroup `
                    --environment $Environment `
                    --image "$acrLoginServer/choperia-api:latest" `
                    --registry-server $acrLoginServer `
                    --registry-username $acrUsername `
                    --registry-password $acrPassword `
                    --target-port 8000 `
                    --ingress external `
                    --cpu 2.0 `
                    --memory 4.0Gi `
                    --min-replicas 1 `
                    --max-replicas 5 `
                    --set-secrets $setSecretsArgs `
                    --set-env-vars $setEnvVarsArgs 2>&1 | Out-Null
                Write-Host "  [AVISO] Container App criado sem volume. Configure manualmente via portal." -ForegroundColor Yellow
                Write-Host "  [INFO] YAML de debug mantido em: $tempYaml" -ForegroundColor Cyan
            }
        } catch {
            Write-Host "  [ERRO] Exceção ao criar Container App: $_" -ForegroundColor Red
            Write-Host "  [INFO] YAML mantido em: $tempYaml para inspeção" -ForegroundColor Cyan
        }
        
        $ErrorActionPreference = "Stop"
    } else {
        # Criar sem YAML (fallback quando não consegue obter envId)
        Write-Host "  [INFO] Criando Container App sem volume (fallback)..." -ForegroundColor Yellow
        $ErrorActionPreference = "Continue"
        
        # Construir comandos para secrets (keyvaultref) e env vars (secretref)
        $setSecretsArgs = @()
        $setSecretsArgs += "acr-password=$acrPassword"
        foreach ($key in $secrets.Keys) {
            $kvName = $key.ToLower().Replace('_', '-')
            $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName"
            $setSecretsArgs += "$kvName=keyvaultref:$secretUri"
        }
        
        $setEnvVarsArgs = @()
        foreach ($envVar in $envVars) {
            $setEnvVarsArgs += $envVar
        }
        foreach ($key in $secretRefs.Keys) {
            $secretName = $secretRefs[$key]
            $setEnvVarsArgs += "$key=secretref:$secretName"
        }
        
        az containerapp create `
            --name $ApiApp `
            --resource-group $ResourceGroup `
            --environment $Environment `
            --image "$acrLoginServer/choperia-api:latest" `
            --registry-server $acrLoginServer `
            --registry-username $acrUsername `
            --registry-password $acrPassword `
            --target-port 8000 `
            --ingress external `
            --cpu 2.0 `
            --memory 4.0Gi `
            --min-replicas 1 `
            --max-replicas 5 `
            --set-secrets $setSecretsArgs `
            --set-env-vars $setEnvVarsArgs 2>&1 | Out-Null
        Write-Host "  [AVISO] Container App criado sem volume. Configure manualmente via portal." -ForegroundColor Yellow
        $ErrorActionPreference = "Stop"
    }
} else {
    Write-Host "[OK] API Container App já existe" -ForegroundColor Green
}

# ==========================================
# CONFIGURAÇÕES PÓS-CRIAÇÃO/VERIFICAÇÃO
# ==========================================

Write-Host ""
Write-Host "=== Configurando Acessos e Permissões ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar/criar Managed Identity
Write-Host "[1/5] Verificando Managed Identity..." -ForegroundColor Yellow
$identity = az containerapp show --name $ApiApp --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json

if (-not $identity -or -not $identity.type -or $identity.type -ne "SystemAssigned") {
    Write-Host "  [INFO] Habilitando Managed Identity..." -ForegroundColor Cyan
    az containerapp identity assign `
        --name $ApiApp `
        --resource-group $ResourceGroup `
        --system-assigned | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Managed Identity habilitada" -ForegroundColor Green
        Start-Sleep -Seconds 5
        $identity = az containerapp show --name $ApiApp --resource-group $ResourceGroup --query "identity" -o json | ConvertFrom-Json
    } else {
        Write-Host "  [ERRO] Falha ao habilitar Managed Identity" -ForegroundColor Red
        $identity = $null
    }
} else {
    Write-Host "  [OK] Managed Identity já está habilitada" -ForegroundColor Green
}

$principalId = $identity.principalId
if ($principalId) {
    Write-Host "  Principal ID: $principalId" -ForegroundColor Gray
}
Write-Host ""

# 2. Verificar/criar secrets no Key Vault
Write-Host "[2/5] Verificando secrets no Key Vault..." -ForegroundColor Yellow
if ($secrets.Count -gt 0) {
    foreach ($key in $secrets.Keys) {
        $kvName = $key.ToLower().Replace('_', '-')
        $value = $secrets[$key]
        
        $ErrorActionPreference = "Continue"
        $secretExists = az keyvault secret show --vault-name $KeyVault --name $kvName --query "name" -o tsv 2>$null
        $ErrorActionPreference = "Stop"
        
        if ($secretExists) {
            Write-Host "  [OK] Secret '$kvName' já existe" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] Criando secret '$kvName'..." -ForegroundColor Cyan
            $tempFile = [System.IO.Path]::GetTempFileName()
            $value | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
            $ErrorActionPreference = "Continue"
            az keyvault secret set --vault-name $KeyVault --name $kvName --file $tempFile 2>&1 | Out-Null
            Remove-Item $tempFile -Force
            $ErrorActionPreference = "Stop"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Secret '$kvName' criado" -ForegroundColor Green
            } else {
                Write-Host "  [ERRO] Falha ao criar secret '$kvName'" -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host "  [AVISO] Nenhum secret encontrado no .env" -ForegroundColor Yellow
}
Write-Host ""

# 3. Verificar/criar permissões RBAC no Key Vault
Write-Host "[3/5] Verificando permissões RBAC no Key Vault..." -ForegroundColor Yellow
if ($principalId) {
    $ErrorActionPreference = "Continue"
    $kvRbacEnabled = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query "properties.enableRbacAuthorization" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($kvRbacEnabled -eq $true) {
        $subscriptionId = az account show --query id -o tsv
        $kvResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault"
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
        
        # Após conceder permissão, atualizar Container App com secrets do Key Vault
        # Isso resolve o "chicken-and-egg": identity precisa existir antes de poder acessar Key Vault
        if ($secrets.Count -gt 0) {
            Write-Host "  [INFO] Atualizando Container App com secrets do Key Vault..." -ForegroundColor Cyan
            Start-Sleep -Seconds 5  # Aguardar propagação da permissão
            
            $setSecretsArgs = @()
            foreach ($key in $secrets.Keys) {
                $kvName = $key.ToLower().Replace('_', '-')
                $secretUri = "https://$KeyVault.vault.azure.net/secrets/$kvName"
                $setSecretsArgs += "$kvName=keyvaultref:$secretUri"
            }
            
            if ($setSecretsArgs.Count -gt 0) {
                $ErrorActionPreference = "Continue"
                az containerapp update `
                    --name $ApiApp `
                    --resource-group $ResourceGroup `
                    --set-secrets $setSecretsArgs 2>&1 | Out-Null
                $ErrorActionPreference = "Stop"
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [OK] Secrets do Key Vault adicionados ao Container App" -ForegroundColor Green
                    
                    # Agora adicionar env vars com secretRef
                    $setEnvVarsArgs = @()
                    foreach ($key in $secretRefs.Keys) {
                        $secretName = $secretRefs[$key]
                        $setEnvVarsArgs += "$key=secretref:$secretName"
                    }
                    
                    if ($setEnvVarsArgs.Count -gt 0) {
                        $ErrorActionPreference = "Continue"
                        az containerapp update `
                            --name $ApiApp `
                            --resource-group $ResourceGroup `
                            --set-env-vars $setEnvVarsArgs 2>&1 | Out-Null
                        $ErrorActionPreference = "Stop"
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  [OK] Env vars com secretRef configuradas" -ForegroundColor Green

                            # ================================
                            # Gerar YAML efetivo do recurso (debug) + verificação
                            # Objetivo: garantir que MYSQL_PASSWORD e OPENAI_API_KEY apareçam no YAML do Container App
                            # ================================
                            try {
                                $expected = @{
                                    "MYSQL_PASSWORD" = "mysql-password"
                                    "OPENAI_API_KEY" = "openai-api-key"
                                }

                                $envList = az containerapp show `
                                    --name $ApiApp `
                                    --resource-group $ResourceGroup `
                                    --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

                                foreach ($k in $expected.Keys) {
                                    $want = $expected[$k]
                                    $found = $envList | Where-Object { $_.name -eq $k } | Select-Object -First 1
                                    if ($found -and $found.secretRef -eq $want) {
                                        Write-Host "  [OK] $k está no recurso via secretRef: $($found.secretRef)" -ForegroundColor Green
                                    } else {
                                        Write-Host "  [AVISO] $k não está no recurso como esperado (secretRef=$want). Verifique o estado do Container App." -ForegroundColor Yellow
                                    }
                                }

                                # Export do YAML efetivo do recurso (sem commitar; .azure é gitignored)
                                $repoRoot = Split-Path $PSScriptRoot -Parent
                                $azureDir2 = Join-Path $repoRoot ".azure"
                                if (-not (Test-Path $azureDir2)) { New-Item -ItemType Directory -Path $azureDir2 -Force | Out-Null }
                                $yamlOut = Join-Path $azureDir2 "container-app-api-kv-effective.yaml"

                                $utf8NoBom2 = New-Object System.Text.UTF8Encoding $false
                                $effectiveYaml = az containerapp show --name $ApiApp --resource-group $ResourceGroup -o yaml 2>$null
                                if ($effectiveYaml) {
                                    [System.IO.File]::WriteAllText($yamlOut, $effectiveYaml, $utf8NoBom2)
                                    Write-Host "  [OK] YAML efetivo salvo em: $yamlOut" -ForegroundColor Green
                                } else {
                                    Write-Host "  [AVISO] Não foi possível exportar YAML efetivo do recurso (az containerapp show -o yaml)" -ForegroundColor Yellow
                                }
                            } catch {
                                Write-Host "  [AVISO] Falha ao verificar/exportar YAML efetivo: $_" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "  [AVISO] Falha ao configurar env vars com secretRef" -ForegroundColor Yellow
                        }
                    }
                } else {
                    Write-Host "  [AVISO] Falha ao adicionar secrets do Key Vault (pode ser problema de permissão ou propagação)" -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Host "  [AVISO] Key Vault não usa RBAC (usa Access Policies)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [AVISO] Não é possível verificar permissões (Managed Identity não habilitada)" -ForegroundColor Yellow
}
Write-Host ""

# 4. Verificar/criar permissões no Storage Account
Write-Host "[4/5] Verificando permissões no Storage Account..." -ForegroundColor Yellow
if ($principalId) {
    # Obter Storage Account do volume
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
        Write-Host "  [AVISO] Volume 'documents-storage' não encontrado no Environment" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [AVISO] Não é possível verificar permissões (Managed Identity não habilitada)" -ForegroundColor Yellow
}
Write-Host ""

# 5. Verificar/montar volume no Container App
Write-Host "[5/5] Verificando volume de documentos no Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$currentVolumes = az containerapp show --name $ApiApp --resource-group $ResourceGroup --query "properties.template.volumes" -o json 2>$null | ConvertFrom-Json
$currentContainer = az containerapp show --name $ApiApp --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json 2>$null | ConvertFrom-Json
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
    Write-Host "  [AVISO] Volume de documentos não está completamente configurado!" -ForegroundColor Yellow
    
    # Verificar se o volume existe no Environment
    $ErrorActionPreference = "Continue"
    $envVolume = az containerapp env storage show `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name documents-storage `
        --query "name" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($envVolume) {
        Write-Host "  [INFO] Volume existe no Environment, mas não está montado no Container App" -ForegroundColor Cyan
        Write-Host "  [INFO] Para configurar o volume mount, execute:" -ForegroundColor Cyan
        Write-Host "    .\infra\old\mount_docs_volume.ps1" -ForegroundColor Gray
        Write-Host "  [INFO] Ou re-execute o bootstrap completo que já inclui essa configuração" -ForegroundColor Cyan
    } else {
        Write-Host "  [ERRO] Volume 'documents-storage' não existe no Environment!" -ForegroundColor Red
        Write-Host "  [INFO] Execute: .\infra\bootstrap_container_apps.ps1 para criar o volume" -ForegroundColor Cyan
    }
} else {
    Write-Host "  [OK] Volume de documentos já está configurado" -ForegroundColor Green
}
Write-Host ""

Write-Host "=== Bootstrap API Concluído ===" -ForegroundColor Green
Write-Host ""
