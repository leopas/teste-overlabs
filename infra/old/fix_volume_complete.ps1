# Script para corrigir TODOS os problemas de acesso ao volume identificados na auditoria

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [string]$DocsPath = "DOC-IA"
)

$ErrorActionPreference = "Stop"

Write-Host "=== CORREÇÃO COMPLETA: Acesso ao Volume ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
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
    if (-not $Environment) {
        $Environment = $state.environmentName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host "[INFO] Documentos locais: $DocsPath" -ForegroundColor Yellow
Write-Host ""

# ==========================================
# PASSO 1: Verificar/Criar File Share e Volume no Environment
# ==========================================
Write-Host "=== PASSO 1: Verificar Volume no Environment ===" -ForegroundColor Cyan
$ErrorActionPreference = "Continue"
$volumeInfo = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage `
    --query "{accountName:properties.azureFile.accountName,shareName:properties.azureFile.shareName}" `
    -o json 2>$null
$ErrorActionPreference = "Stop"

if ($volumeInfo) {
    $volumeObj = $volumeInfo | ConvertFrom-Json
    $storageAccount = $volumeObj.accountName
    $shareName = $volumeObj.shareName
    Write-Host "[OK] Volume já existe no Environment" -ForegroundColor Green
} else {
    Write-Host "[INFO] Criando volume no Environment..." -ForegroundColor Yellow
    
    # Obter Storage Account
    $storageAccounts = az storage account list --resource-group $ResourceGroup --query "[].name" -o tsv
    if (-not $storageAccounts) {
        Write-Host "[ERRO] Nenhum Storage Account encontrado!" -ForegroundColor Red
        exit 1
    }
    $storageAccount = ($storageAccounts | Select-Object -First 1)
    $storageKey = az storage account keys list --account-name $storageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
    $shareName = "documents"
    
    # Criar File Share se não existir
    $ErrorActionPreference = "Continue"
    $shareExists = az storage share show --account-name $storageAccount --account-key $storageKey --name $shareName 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[INFO] Criando File Share '$shareName'..." -ForegroundColor Yellow
        az storage share create --account-name $storageAccount --account-key $storageKey --name $shareName --quota 10 | Out-Null
    }
    
    # Criar volume no Environment
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name documents-storage `
        --azure-file-account-name $storageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $shareName `
        --access-mode ReadWrite 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Volume criado no Environment" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao criar volume no Environment" -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# ==========================================
# PASSO 2: Adicionar Volume e Volume Mount no Container App
# ==========================================
Write-Host "=== PASSO 2: Configurar Volume no Container App ===" -ForegroundColor Cyan

# Obter configuração atual
$currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json | ConvertFrom-Json
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv

# Verificar se já tem volume
$volumes = @()
if ($currentConfig.properties.template.volumes) {
    $volumes = $currentConfig.properties.template.volumes
}

$hasVolume = $false
foreach ($vol in $volumes) {
    if ($vol.name -eq "documents-storage") {
        $hasVolume = $true
        break
    }
}

if (-not $hasVolume) {
    Write-Host "[INFO] Adicionando volume 'documents-storage'..." -ForegroundColor Yellow
    $volumes += @{
        name = "documents-storage"
        storageType = "AzureFile"
        storageName = "documents-storage"
    }
} else {
    Write-Host "[OK] Volume já está definido" -ForegroundColor Green
}

# Verificar se já tem volume mount
$volumeMounts = @()
if ($currentConfig.properties.template.containers[0].volumeMounts) {
    $volumeMounts = $currentConfig.properties.template.containers[0].volumeMounts
}

$hasVolumeMount = $false
foreach ($vm in $volumeMounts) {
    if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
        $hasVolumeMount = $true
        break
    }
}

if (-not $hasVolumeMount) {
    Write-Host "[INFO] Adicionando volume mount '/app/DOC-IA'..." -ForegroundColor Yellow
    $volumeMounts += @{
        volumeName = "documents-storage"
        mountPath = "/app/DOC-IA"
    }
} else {
    Write-Host "[OK] Volume mount já está configurado" -ForegroundColor Green
}

# Se precisa atualizar, fazer update via YAML
if (-not $hasVolume -or -not $hasVolumeMount) {
    # Obter env vars existentes
    $envVars = @()
    if ($currentConfig.properties.template.containers[0].env) {
        foreach ($env in $currentConfig.properties.template.containers[0].env) {
            $envVars += "$($env.name)=$($env.value)"
        }
    }
    
    # Garantir DOCS_ROOT
    $hasDocsRoot = $false
    foreach ($envVar in $envVars) {
        if ($envVar -match "^DOCS_ROOT=") {
            $hasDocsRoot = $true
            break
        }
    }
    if (-not $hasDocsRoot) {
        $envVars += "DOCS_ROOT=/app/DOC-IA"
    }
    
    # Construir YAML
    $envVarsYaml = ""
    foreach ($envVar in $envVars) {
        $parts = $envVar -split '=', 2
        $name = $parts[0]
        $value = $parts[1]
        $value = $value -replace '"', '\"'
        $envVarsYaml += "      - name: $name`n        value: `"$value`"`n"
    }
    
    $volumesYaml = ""
    foreach ($vol in $volumes) {
        $volumesYaml += "    - name: $($vol.name)`n      storageType: $($vol.storageType)`n      storageName: $($vol.storageName)`n"
    }
    
    $volumeMountsYaml = ""
    foreach ($vm in $volumeMounts) {
        $volumeMountsYaml += "      - volumeName: $($vm.volumeName)`n        mountPath: $($vm.mountPath)`n"
    }
    
    $yamlContent = @"
properties:
  environmentId: $envId
  template:
    containers:
    - name: $($currentConfig.properties.template.containers[0].name)
      image: $($currentConfig.properties.template.containers[0].image)
      env:
$envVarsYaml      resources:
        cpu: $($currentConfig.properties.template.containers[0].resources.cpu)
        memory: $($currentConfig.properties.template.containers[0].resources.memory)
      volumeMounts:
$volumeMountsYaml    scale:
      minReplicas: $($currentConfig.properties.template.scale.minReplicas)
      maxReplicas: $($currentConfig.properties.template.scale.maxReplicas)
    volumes:
$volumesYaml
"@
    
    $yamlFile = [System.IO.Path]::GetTempFileName() + ".yaml"
    $yamlContent | Out-File -FilePath $yamlFile -Encoding utf8 -NoNewline
    
    Write-Host "[INFO] Atualizando Container App com volume mount..." -ForegroundColor Yellow
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --yaml $yamlFile | Out-Null
    
    Remove-Item $yamlFile -Force
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Container App atualizado com volume mount" -ForegroundColor Green
        Write-Host "[INFO] Aguardando 15s para a atualização ser aplicada..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } else {
        Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# ==========================================
# PASSO 3: Upload de Documentos
# ==========================================
Write-Host "=== PASSO 3: Upload de Documentos ===" -ForegroundColor Cyan

if (-not (Test-Path $DocsPath)) {
    Write-Host "[AVISO] Diretório local '$DocsPath' não encontrado. Pulando upload." -ForegroundColor Yellow
} else {
    Write-Host "[INFO] Verificando arquivos no File Share..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $storageKey = az storage account keys list --account-name $storageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
    $existingFiles = az storage file list `
        --account-name $storageAccount `
        --account-key $storageKey `
        --share-name $shareName `
        --query "[].name" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    
    if ($existingFiles) {
        $fileCount = ($existingFiles | Measure-Object).Count
        Write-Host "[INFO] File Share já contém $fileCount arquivo(s)" -ForegroundColor Yellow
        $upload = Read-Host "Deseja fazer upload mesmo assim? (S/N)"
        if ($upload -ne "S") {
            Write-Host "[INFO] Pulando upload" -ForegroundColor Gray
        } else {
            Write-Host "[INFO] Fazendo upload dos documentos..." -ForegroundColor Yellow
            
            # Tentar upload em lote primeiro
            $ErrorActionPreference = "Continue"
            az storage file upload-batch `
                --account-name $storageAccount `
                --account-key $storageKey `
                --destination $shareName `
                --source $DocsPath `
                --overwrite 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] Documentos enviados para o File Share" -ForegroundColor Green
            } else {
                Write-Host "[AVISO] Upload em lote falhou. Tentando arquivo por arquivo..." -ForegroundColor Yellow
                
                # Fallback: upload arquivo por arquivo
                $localFiles = Get-ChildItem -Path $DocsPath -File -Recurse
                $successCount = 0
                $failCount = 0
                
                foreach ($file in $localFiles) {
                    $relativePath = $file.FullName.Substring((Resolve-Path $DocsPath).Path.Length + 1)
                    $relativePath = $relativePath.Replace('\', '/')
                    
                    # Criar diretorio se necessario
                    $dirPath = Split-Path -Path $relativePath -Parent
                    if ($dirPath -and $dirPath -ne ".") {
                        az storage directory create `
                            --account-name $storageAccount `
                            --account-key $storageKey `
                            --share-name $shareName `
                            --name $dirPath 2>&1 | Out-Null
                    }
                    
                    # Remover arquivo existente se houver
                    az storage file delete `
                        --account-name $storageAccount `
                        --account-key $storageKey `
                        --share-name $shareName `
                        --path $relativePath 2>&1 | Out-Null
                    
                    # Upload do arquivo
                    $uploadError = az storage file upload `
                        --account-name $storageAccount `
                        --account-key $storageKey `
                        --share-name $shareName `
                        --source $file.FullName `
                        --path $relativePath 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        $successCount++
                        Write-Host "  OK: $relativePath" -ForegroundColor Gray
                    } else {
                        $failCount++
                        Write-Host "  ERRO: $relativePath" -ForegroundColor Yellow
                        if ($uploadError) {
                            Write-Host "    Detalhes: $uploadError" -ForegroundColor DarkYellow
                        }
                    }
                }
                
                Write-Host ""
                if ($successCount -gt 0) {
                    $msg = "[OK] " + $successCount.ToString() + " arquivo(s) enviado(s) com sucesso"
                    Write-Host $msg -ForegroundColor Green
                }
                if ($failCount -gt 0) {
                    $msg = "[AVISO] " + $failCount.ToString() + " arquivo(s) falharam no upload"
                    Write-Host $msg -ForegroundColor Yellow
                }
            }
            $ErrorActionPreference = "Stop"
        }
    } else {
        Write-Host "[INFO] File Share esta vazio. Fazendo upload dos documentos..." -ForegroundColor Yellow
        
        # Tentar upload em lote primeiro
        $ErrorActionPreference = "Continue"
        az storage file upload-batch `
            --account-name $storageAccount `
            --account-key $storageKey `
            --destination $shareName `
            --source $DocsPath `
            --overwrite 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Documentos enviados para o File Share" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Upload em lote falhou. Tentando arquivo por arquivo..." -ForegroundColor Yellow
            
            # Fallback: upload arquivo por arquivo
            $localFiles = Get-ChildItem -Path $DocsPath -File -Recurse
            $successCount = 0
            $failCount = 0
            
            foreach ($file in $localFiles) {
                $relativePath = $file.FullName.Substring((Resolve-Path $DocsPath).Path.Length + 1)
                $relativePath = $relativePath.Replace('\', '/')
                
                # Criar diretorio se necessario
                $dirPath = Split-Path -Path $relativePath -Parent
                if ($dirPath -and $dirPath -ne ".") {
                    az storage directory create `
                        --account-name $storageAccount `
                        --account-key $storageKey `
                        --share-name $shareName `
                        --name $dirPath 2>&1 | Out-Null
                }
                
                # Remover arquivo existente se houver
                az storage file delete `
                    --account-name $storageAccount `
                    --account-key $storageKey `
                    --share-name $shareName `
                    --path $relativePath 2>&1 | Out-Null
                
                # Upload do arquivo
                $uploadError = az storage file upload `
                    --account-name $storageAccount `
                    --account-key $storageKey `
                    --share-name $shareName `
                    --source $file.FullName `
                    --path $relativePath 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $successCount++
                    Write-Host "  OK: $relativePath" -ForegroundColor Gray
                } else {
                    $failCount++
                    Write-Host "  ERRO: $relativePath" -ForegroundColor Yellow
                    if ($uploadError) {
                        Write-Host "    Detalhes: $uploadError" -ForegroundColor DarkYellow
                    }
                }
            }
            
            Write-Host ""
            if ($successCount -gt 0) {
                $msg = "[OK] " + $successCount.ToString() + " arquivo(s) enviado(s) com sucesso"
                Write-Host $msg -ForegroundColor Green
            }
            if ($failCount -gt 0) {
                $msg = "[AVISO] " + $failCount.ToString() + " arquivo(s) falharam no upload"
                Write-Host $msg -ForegroundColor Yellow
            }
        }
        $ErrorActionPreference = "Stop"
    }
}
Write-Host ""

# ==========================================
# PASSO 4: Reiniciar Container App
# ==========================================
Write-Host "=== PASSO 4: Reiniciar Container App ===" -ForegroundColor Cyan
Write-Host "[INFO] Forcando nova revision para aplicar mudancas..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App atualizado (nova revision sera criada)" -ForegroundColor Green
    
    # Aguardar ate que a revision esteja pronta (max 5 minutos)
    Write-Host "[INFO] Aguardando revision ficar pronta..." -ForegroundColor Yellow
    $maxWait = 300
    $elapsed = 0
    $revisionReady = $false
    
    while ($elapsed -lt $maxWait) {
        $revisionStatus = az containerapp revision list `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --query "[?properties.active==\`true\`].properties.provisioningState" -o tsv 2>$null
        
        if ($revisionStatus -eq "Succeeded") {
            $revisionReady = $true
            break
        }
        
        Write-Host "  Aguardando... (${elapsed}s/${maxWait}s)" -ForegroundColor Gray
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
    
    if ($revisionReady) {
        Write-Host "[OK] Revision esta pronta" -ForegroundColor Green
        Start-Sleep -Seconds 15
    } else {
        Write-Host "[AVISO] Revision ainda nao esta pronta apos $maxWait segundos" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] Falha ao atualizar Container App" -ForegroundColor Yellow
}
Write-Host ""

# ==========================================
# PASSO 5: Verificação Final
# ==========================================
Write-Host "=== PASSO 5: Verificação Final ===" -ForegroundColor Cyan
Write-Host "[INFO] Verificando se /app/DOC-IA está acessível..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' && ls -la /app/DOC-IA | head -10 || echo 'NOT_FOUND'" 2>&1

if ($checkOutput -match "EXISTS") {
    Write-Host "[OK] Volume está acessível no container!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Conteúdo do diretório:" -ForegroundColor Cyan
    Write-Host $checkOutput
    Write-Host ""
    Write-Host "[OK] TUDO CORRIGIDO COM SUCESSO!" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Você pode executar a ingestão agora:" -ForegroundColor Cyan
    Write-Host "  .\infra\run_ingest_in_container.ps1 -TruncateFirst" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Volume ainda não está acessível" -ForegroundColor Yellow
    Write-Host "[INFO] Aguarde mais alguns minutos e execute:" -ForegroundColor Cyan
    Write-Host "  .\infra\check_volume_mount.ps1" -ForegroundColor Gray
    Write-Host "  .\infra\audit_volume_access.ps1" -ForegroundColor Gray
}
$ErrorActionPreference = "Stop"

Write-Host ""
