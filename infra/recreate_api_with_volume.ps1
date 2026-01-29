# Script para recriar o Container App da API com volume mount desde o inicio
# IMPORTANTE: Isso vai criar uma nova revision e pode causar downtime temporario

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$Environment = $null,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Recriar Container App da API com Volume Mount ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[AVISO] Este script vai recriar o Container App com volume mount." -ForegroundColor Yellow
Write-Host "[AVISO] Isso pode causar downtime temporario durante a recriacao." -ForegroundColor Yellow
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Deseja continuar? (S/N)"
    if ($confirm -ne "S") {
        Write-Host "[INFO] Operacao cancelada." -ForegroundColor Gray
        exit 0
    }
}

# Carregar deploy_state.json se nao fornecido
if (-not $ResourceGroup -or -not $ApiAppName -or -not $Environment) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile nao encontrado." -ForegroundColor Red
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

# 1. Obter ACR primeiro (antes de qualquer coisa)
Write-Host "[INFO] Obtendo informacoes do ACR..." -ForegroundColor Yellow

# Obter ACR name do deploy_state.json
$acrName = $null
$stateFile = ".azure/deploy_state.json"
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile | ConvertFrom-Json
    if ($state.acrName) {
        $acrName = $state.acrName
    }
}

# Se nao encontrou, tentar obter da configuracao atual do Container App
if (-not $acrName) {
    $ErrorActionPreference = "Continue"
    $acrServer = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.configuration.registries[0].server" -o tsv 2>$null
    $ErrorActionPreference = "Stop"
    if ($acrServer) {
        $acrName = ($acrServer -split '\.')[0]
    }
}

# Se ainda nao encontrou, usar o padrao
if (-not $acrName) {
    $acrName = "acrchoperia"
    Write-Host "[AVISO] Usando ACR padrao: $acrName" -ForegroundColor Yellow
}

Write-Host "[INFO] ACR Name: $acrName" -ForegroundColor Gray

# Verificar se ACR existe (pode estar em outro resource group)
$ErrorActionPreference = "Continue"
$acrExists = az acr show --name $acrName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[AVISO] ACR '$acrName' nao encontrado. Buscando em todos os resource groups..." -ForegroundColor Yellow
    
    # Buscar ACR em todos os resource groups
    $allAcrs = az acr list --query "[?name=='$acrName']" -o json | ConvertFrom-Json
    if ($allAcrs -and $allAcrs.Count -gt 0) {
        $acrResourceGroup = $allAcrs[0].resourceGroup
        Write-Host "[OK] ACR encontrado no resource group: $acrResourceGroup" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] ACR '$acrName' nao encontrado em nenhum resource group." -ForegroundColor Red
        Write-Host "[INFO] Liste os ACRs disponiveis: az acr list --query '[].name' -o tsv" -ForegroundColor Yellow
        exit 1
    }
}
$ErrorActionPreference = "Stop"

# Obter credenciais do ACR (sem especificar resource group, busca em todos)
$acrLoginServer = az acr show --name $acrName --query loginServer -o tsv
$acrUsername = az acr credential show --name $acrName --query username -o tsv
$acrPassword = az acr credential show --name $acrName --query passwords[0].value -o tsv

Write-Host "[OK] ACR configurado: $acrLoginServer" -ForegroundColor Green
Write-Host ""

# 2. Obter configuracao atual (se Container App ainda existe)
Write-Host "[INFO] Verificando se Container App existe..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$currentConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = "Stop"

if (-not $currentConfig) {
    Write-Host "[AVISO] Container App nao existe. Usando configuracao padrao." -ForegroundColor Yellow
    
    # Criar configuracao padrao
    $currentConfig = @{
        properties = @{
            template = @{
                containers = @(
                    @{
                        name = "api"
                        image = "$acrLoginServer/choperia-api:latest"
                        env = @()
                        resources = @{
                            cpu = 2.0
                            memory = "4.0Gi"
                        }
                    }
                )
                scale = @{
                    minReplicas = 1
                    maxReplicas = 5
                }
            }
        }
    }
    
    # Carregar env vars do deploy_state.json se disponivel
    $stateFile = ".azure/deploy_state.json"
    if (Test-Path $stateFile) {
        Write-Host "[INFO] Carregando configuracao do deploy_state.json..." -ForegroundColor Yellow
        # Vamos usar as env vars que estavam configuradas antes
    }
} else {
    Write-Host "[OK] Configuracao atual obtida" -ForegroundColor Green
}

# 3. Obter environment ID e location (sem capturar stderr)
$envId = az containerapp env show --name $Environment --resource-group $ResourceGroup --query id -o tsv 2>$null
$location = az containerapp env show --name $Environment --resource-group $ResourceGroup --query location -o tsv 2>$null

# Limpar e validar valores
$envId = $envId.Trim()
$location = $location.Trim()

if (-not $location -or $location -match "error|not found") {
    $location = "brazilsouth"  # Fallback padrão
}
# Garantir que location é código (não display name)
$location = $location.ToLower().Replace(' ', '')

# 4. Construir env vars
$envVars = @()
if ($currentConfig.properties.template.containers[0].env) {
    foreach ($env in $currentConfig.properties.template.containers[0].env) {
        $envVars += @{
            name = $env.name
            value = $env.value
        }
    }
}

# Garantir DOCS_ROOT
$hasDocsRoot = $false
foreach ($envVar in $envVars) {
    if ($envVar.name -eq "DOCS_ROOT") {
        $hasDocsRoot = $true
        break
    }
}
if (-not $hasDocsRoot) {
    $envVars += @{
        name = "DOCS_ROOT"
        value = "/app/DOC-IA"
    }
}

# Construir YAML de env vars
$envVarsYaml = ""
foreach ($env in $envVars) {
    $envValue = $env.value -replace '"', '\"'
    $envVarsYaml += "      - name: $($env.name)`n        value: `"$envValue`"`n"
}

# 5. Construir YAML completo (igual ao Qdrant que funcionou)
$yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
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
    - name: acr-password
      value: $acrPassword
  template:
    containers:
    - name: $($currentConfig.properties.template.containers[0].name)
      image: $($currentConfig.properties.template.containers[0].image)
      env:
$envVarsYaml
      resources:
        cpu: $($currentConfig.properties.template.containers[0].resources.cpu)
        memory: $($currentConfig.properties.template.containers[0].resources.memory)
      volumeMounts:
      - volumeName: docs
        mountPath: /app/DOC-IA
    scale:
      minReplicas: $($currentConfig.properties.template.scale.minReplicas)
      maxReplicas: $($currentConfig.properties.template.scale.maxReplicas)
    volumes:
    - name: docs
      storageType: AzureFile
      storageName: documents-storage
"@

$yamlFile = [System.IO.Path]::GetTempFileName() + ".yaml"
# Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($yamlFile, $yamlContent, $utf8NoBom)

Write-Host "[INFO] YAML salvo em: $yamlFile" -ForegroundColor Gray
Write-Host "[INFO] Recriando Container App com volume mount..." -ForegroundColor Yellow

# 5. Deletar Container App existente (se ainda existe)
if ($currentConfig.properties) {
    Write-Host "[INFO] Deletando Container App existente..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    az containerapp delete `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --yes 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Container App deletado" -ForegroundColor Green
        # Aguardar um pouco
        Start-Sleep -Seconds 10
    } else {
        Write-Host "[AVISO] Container App pode nao existir ou ja foi deletado." -ForegroundColor Yellow
    }
    $ErrorActionPreference = "Stop"
} else {
    Write-Host "[INFO] Container App nao existe. Pulando delecao." -ForegroundColor Yellow
}

# 6. Criar Container App novamente com volume mount (igual ao Qdrant)
Write-Host "[INFO] Criando Container App com volume mount..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az containerapp create `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --yaml $yamlFile 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Container App recriado com volume mount!" -ForegroundColor Green
    
    # Verificar se foi aplicado
    Write-Host "[INFO] Verificando se volume mount foi aplicado..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    $verifyMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json | ConvertFrom-Json
    
    if ($verifyMounts) {
        Write-Host "[OK] Volume mount confirmado!" -ForegroundColor Green
        foreach ($vm in $verifyMounts) {
            Write-Host "  - Volume: $($vm.volumeName), Mount: $($vm.mountPath)" -ForegroundColor Gray
        }
    } else {
        Write-Host "[AVISO] Volume mount nao foi confirmado. Verifique manualmente." -ForegroundColor Yellow
    }
    
    Remove-Item $yamlFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[ERRO] Falha ao recriar Container App" -ForegroundColor Red
    Write-Host "[INFO] YAML mantido em: $yamlFile para inspecao" -ForegroundColor Yellow
    Write-Host "[INFO] Tente criar manualmente usando o YAML" -ForegroundColor Cyan
    exit 1
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[OK] Container App recriado com sucesso!" -ForegroundColor Green
Write-Host "[INFO] Aguarde alguns minutos e verifique: .\infra\verify_volume_working.ps1" -ForegroundColor Cyan
Write-Host ""
