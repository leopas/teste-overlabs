# Script para montar o volume de documentos no Container App existente
# Verifica se o volume esta configurado e monta se necessario

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [switch]$UploadDocs
)

$ErrorActionPreference = "Stop"

Write-Host "=== Montar Volume de Documentos no Container App ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se nao fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado. Forneca -ResourceGroup, -ApiAppName e -Environment." -ForegroundColor Red
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
Write-Host ""

# 1. Verificar Storage Account e File Share
Write-Host "[INFO] Verificando Storage Account e File Share..." -ForegroundColor Yellow
$storageAccounts = az storage account list --resource-group $ResourceGroup --query "[].name" -o tsv
if (-not $storageAccounts) {
    Write-Host "[ERRO] Nenhum Storage Account encontrado no Resource Group" -ForegroundColor Red
    exit 1
}

$StorageAccount = ($storageAccounts | Select-Object -First 1)
Write-Host "[OK] Storage Account: $StorageAccount" -ForegroundColor Green

$storageKey = az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
$DocsFileShare = "documents"

$ErrorActionPreference = "Continue"
$shareExists = az storage share show --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando File Share '$DocsFileShare'..." -ForegroundColor Yellow
    az storage share create --account-name $StorageAccount --account-key $storageKey --name $DocsFileShare --quota 10 | Out-Null
    Write-Host "[OK] File Share criado" -ForegroundColor Green
} else {
    Write-Host "[OK] File Share '$DocsFileShare' ja existe" -ForegroundColor Green
}
Write-Host ""

# 2. Configurar volume no Environment
Write-Host "[INFO] Configurando volume 'documents-storage' no Environment..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$volumeExists = az containerapp env storage show `
    --name $Environment `
    --resource-group $ResourceGroup `
    --storage-name documents-storage 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando volume no Environment..." -ForegroundColor Yellow
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name documents-storage `
        --azure-file-account-name $StorageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $DocsFileShare `
        --access-mode ReadWrite 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Volume configurado no Environment" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao configurar volume no Environment" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Volume ja existe no Environment" -ForegroundColor Green
}
$ErrorActionPreference = "Stop"
Write-Host ""

# 3. Verificar se o Container App ja tem o volume montado
Write-Host "[INFO] Verificando se Container App tem volume montado..." -ForegroundColor Yellow
$appConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0]" -o json | ConvertFrom-Json

$hasVolumeMount = $false
if ($appConfig.volumeMounts) {
    foreach ($vm in $appConfig.volumeMounts) {
        if ($vm.volumeName -eq "documents-storage" -and $vm.mountPath -eq "/app/DOC-IA") {
            $hasVolumeMount = $true
            Write-Host "[OK] Volume ja esta montado em /app/DOC-IA" -ForegroundColor Green
            break
        }
    }
}

if (-not $hasVolumeMount) {
    Write-Host "[INFO] Volume nao esta montado. Adicionando volume mount..." -ForegroundColor Yellow
    
    # Obter configuracao atual do Container App
    $currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json | ConvertFrom-Json
    
    # Verificar se ja tem volumes definidos
    $volumes = @()
    if ($currentConfig.properties.template.volumes) {
        $volumes = $currentConfig.properties.template.volumes
    }
    
    # Adicionar volume se nao existir
    $hasVolume = $false
    foreach ($vol in $volumes) {
        if ($vol.name -eq "documents-storage") {
            $hasVolume = $true
            break
        }
    }
    
    if (-not $hasVolume) {
        $volumes += @{
            name = "documents-storage"
            storageType = "AzureFile"
            storageName = "documents-storage"
        }
    }
    
    # Adicionar volume mount no container
    $volumeMounts = @()
    if ($currentConfig.properties.template.containers[0].volumeMounts) {
        $volumeMounts = $currentConfig.properties.template.containers[0].volumeMounts
    }
    
    $volumeMounts += @{
        volumeName = "documents-storage"
        mountPath = "/app/DOC-IA"
    }
    
    # Construir JSON para atualizacao usando YAML (Azure CLI aceita YAML melhor)
    $envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv
    
    # Obter env vars existentes
    $envVarsYaml = ""
    if ($currentConfig.properties.template.containers[0].env) {
        foreach ($env in $currentConfig.properties.template.containers[0].env) {
            $envName = $env.name
            $envValue = $env.value
            # Escapar aspas no valor
            $envValue = $envValue -replace '"', '\"'
            $envVarsYaml += "      - name: $envName`n        value: `"$envValue`"`n"
        }
    }
    
    # Garantir DOCS_ROOT
    $hasDocsRoot = $false
    if ($currentConfig.properties.template.containers[0].env) {
        foreach ($env in $currentConfig.properties.template.containers[0].env) {
            if ($env.name -eq "DOCS_ROOT") {
                $hasDocsRoot = $true
                break
            }
        }
    }
    if (-not $hasDocsRoot) {
        $envVarsYaml += "      - name: DOCS_ROOT`n        value: `/app/DOC-IA``n"
    }
    
    # Construir YAML
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
    Write-Host "[DEBUG] YAML salvo em: $yamlFile" -ForegroundColor Gray
    $ErrorActionPreference = "Continue"
    $updateOutput = az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --yaml $yamlFile 2>&1
    $ErrorActionPreference = "Stop"
    
    # Manter arquivo temporariamente para debug se falhar
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[DEBUG] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Yellow
    } else {
        Remove-Item $yamlFile -Force
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Container App atualizado com volume mount" -ForegroundColor Green
        
        # Verificar se o volume foi realmente adicionado
        Start-Sleep -Seconds 5
        $verifyConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json | ConvertFrom-Json
        $volumeAdded = $false
        if ($verifyConfig) {
            foreach ($vol in $verifyConfig) {
                if ($vol.name -eq "documents-storage") {
                    $volumeAdded = $true
                    break
                }
            }
        }
        
        if ($volumeAdded) {
            Write-Host "[OK] Volume confirmado no Container App" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Volume pode nao ter sido aplicado. Tentando novamente..." -ForegroundColor Yellow
        }
        
        Write-Host "[INFO] Forcando nova revision para aplicar volume mount..." -ForegroundColor Yellow
        
        # Forcar nova revision atualizando uma variavel de ambiente temporaria
        $ErrorActionPreference = "Continue"
        az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --set-env-vars "VOLUME_MOUNT_TRIGGER=$(Get-Date -Format 'yyyyMMddHHmmss')" 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
        
        Write-Host "[INFO] Aguardando 60s para a nova revision ficar pronta..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    } else {
        Write-Host "[ERRO] Falha ao atualizar Container App" -ForegroundColor Red
        Write-Host "Erro: $updateOutput" -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# 4. Upload de documentos se solicitado
if ($UploadDocs) {
    Write-Host "[INFO] Fazendo upload dos documentos locais para o Azure File Share..." -ForegroundColor Yellow
    $localDocsPath = "DOC-IA"
    
    if (-not (Test-Path $localDocsPath)) {
        Write-Host "[AVISO] Pasta local '$localDocsPath' nao encontrada. Pulando upload." -ForegroundColor Yellow
    } else {
        Write-Host "[INFO] Listando arquivos locais..." -ForegroundColor Gray
        $localFiles = Get-ChildItem -Path $localDocsPath -File -Recurse
        $fileCount = $localFiles.Count
        Write-Host "  Encontrados $fileCount arquivo(s)" -ForegroundColor Gray
        Write-Host ""
        
        $ErrorActionPreference = "Continue"
        
        # Tentar upload usando upload-batch primeiro
        Write-Host "[INFO] Tentando upload em lote..." -ForegroundColor Yellow
        az storage file upload-batch `
            --account-name $StorageAccount `
            --account-key $storageKey `
            --destination $DocsFileShare `
            --source $localDocsPath `
            --overwrite 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Documentos enviados para o Azure File Share" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Upload em lote falhou. Tentando arquivo por arquivo..." -ForegroundColor Yellow
            
            # Fallback: upload arquivo por arquivo
            $successCount = 0
            $failCount = 0
            
            foreach ($file in $localFiles) {
                $relativePath = $file.FullName.Substring((Resolve-Path $localDocsPath).Path.Length + 1)
                $relativePath = $relativePath.Replace('\', '/')
                
                # Criar diretorio se necessario
                $dirPath = Split-Path -Path $relativePath -Parent
                if ($dirPath -and $dirPath -ne ".") {
                    $ErrorActionPreference = "Continue"
                    az storage directory create `
                        --account-name $StorageAccount `
                        --account-key $storageKey `
                        --share-name $DocsFileShare `
                        --name $dirPath 2>&1 | Out-Null
                    $ErrorActionPreference = "Stop"
                }
                
                # Upload do arquivo (remover arquivo existente primeiro se necessario)
                $ErrorActionPreference = "Continue"
                
                # Tentar remover arquivo existente (ignorar erro se nao existir)
                az storage file delete `
                    --account-name $StorageAccount `
                    --account-key $storageKey `
                    --share-name $DocsFileShare `
                    --path $relativePath 2>&1 | Out-Null
                
                # Upload do arquivo
                $uploadError = az storage file upload `
                    --account-name $StorageAccount `
                    --account-key $storageKey `
                    --share-name $DocsFileShare `
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
                $ErrorActionPreference = "Stop"
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
    Write-Host ""
}

# 5. Verificar se o container esta rodando e o volume esta acessivel
Write-Host "[INFO] Verificando se o container esta rodando..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Aguardar ate que a revision esteja pronta (max 5 minutos)
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
    
    $progressMsg = "  Aguardando revision ficar pronta... (" + $elapsed.ToString() + "s/" + $maxWait.ToString() + "s)"
    Write-Host $progressMsg -ForegroundColor Gray
    Start-Sleep -Seconds 10
    $elapsed += 10
}

if ($revisionReady) {
    Write-Host "[OK] Container esta rodando" -ForegroundColor Green
    
    # Aguardar mais um pouco para garantir que esta totalmente iniciado
    Write-Host "[INFO] Aguardando 15s para container iniciar completamente..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    
    # Verificar se o volume esta acessivel no container
    Write-Host "[INFO] Verificando se /app/DOC-IA esta acessivel no container..." -ForegroundColor Yellow
    $checkCommand = "if test -d /app/DOC-IA; then echo 'EXISTS'; ls -la /app/DOC-IA | head -10; else echo 'NOT_FOUND'; fi"
    $checkOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command $checkCommand 2>&1
    
    if ($checkOutput -match "EXISTS") {
        Write-Host "[OK] /app/DOC-IA esta acessivel no container!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Conteudo do diretorio:" -ForegroundColor Cyan
        Write-Host $checkOutput
    } elseif ($checkOutput -match "NOT_FOUND") {
        Write-Host "[AVISO] /app/DOC-IA ainda nao esta acessivel." -ForegroundColor Yellow
        Write-Host "[INFO] O volume pode levar alguns minutos para ser montado." -ForegroundColor Yellow
        Write-Host "[INFO] Execute: .\infra\check_volume_mount.ps1 para verificar novamente" -ForegroundColor Yellow
    } else {
        Write-Host "[AVISO] Nao foi possivel verificar (container pode estar iniciando)" -ForegroundColor Yellow
        Write-Host "[INFO] Execute: .\infra\check_volume_mount.ps1 para verificar novamente" -ForegroundColor Yellow
    }
} else {
    Write-Host "[AVISO] Container ainda nao esta pronto apos $maxWait segundos" -ForegroundColor Yellow
    Write-Host "[INFO] Execute: .\infra\check_volume_mount.ps1 para verificar o status" -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Concluido! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Proximos passos:" -ForegroundColor Yellow
Write-Host "  1. Se os documentos nao foram enviados, execute: .\infra\mount_docs_volume.ps1 -UploadDocs" -ForegroundColor Gray
Write-Host "  2. Execute a ingestao: .\infra\run_ingest_in_container.ps1" -ForegroundColor Gray
Write-Host ""
