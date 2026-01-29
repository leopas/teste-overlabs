# Script para criar/verificar Qdrant Container App com volume persistente
# Uso: .\infra\bootstrap_qdrant.ps1 -ResourceGroup "rg-overlabs-prod" -Environment "env-overlabs-prod-248" -QdrantApp "app-overlabs-qdrant-prod-248" -StorageAccount "saoverlabsprod248" -FileShare "qdrant-storage"

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    
    [Parameter(Mandatory=$true)]
    [string]$QdrantApp,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccount,
    
    [Parameter(Mandatory=$true)]
    [string]$FileShare
)

$ErrorActionPreference = "Stop"

Write-Host "=== Bootstrap Qdrant Container App ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Environment: $Environment" -ForegroundColor Yellow
Write-Host "[INFO] Qdrant Container App: $QdrantApp" -ForegroundColor Yellow
Write-Host "[INFO] Storage Account: $StorageAccount" -ForegroundColor Yellow
Write-Host "[INFO] File Share: $FileShare" -ForegroundColor Yellow
Write-Host ""

# Verificar se já existe
Write-Host "[INFO] Verificando Qdrant Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $QdrantApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Criando Qdrant Container App..." -ForegroundColor Yellow
    
    # Obter storage key
    $storageKey = az storage account keys list --account-name $StorageAccount --resource-group $ResourceGroup --query "[0].value" -o tsv
    
    # Criar volume persistente no Environment
    Write-Host "[INFO] Configurando volume no Environment..." -ForegroundColor Cyan
    $ErrorActionPreference = "Continue"
    az containerapp env storage set `
        --name $Environment `
        --resource-group $ResourceGroup `
        --storage-name qdrant-storage `
        --azure-file-account-name $StorageAccount `
        --azure-file-account-key $storageKey `
        --azure-file-share-name $FileShare `
        --access-mode ReadWrite 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    
    # Obter environment ID e location (sem capturar stderr)
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
    
    # Criar arquivo YAML temporário para o Qdrant com volume
    # Adicionar location, aspas no envId, allowInsecure e traffic para evitar problemas de parsing
    $yamlContent = @"
location: $location
properties:
  environmentId: "$envId"
  configuration:
    ingress:
      external: false
      allowInsecure: false
      targetPort: 6333
      transport: http
      traffic:
      - weight: 100
        latestRevision: true
  template:
    containers:
    - name: qdrant
      image: qdrant/qdrant:v1.7.4
      env:
      - name: QDRANT__SERVICE__GRPC_PORT
        value: "6334"
      resources:
        cpu: 1.0
        memory: 2.0Gi
      volumeMounts:
      - volumeName: qdrant-storage
        mountPath: /qdrant/storage
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: qdrant-storage
      storageType: AzureFile
      storageName: qdrant-storage
"@
    
    $tempYaml = [System.IO.Path]::GetTempFileName() + ".yaml"
    # Escrever sem BOM (Byte Order Mark) para evitar erro de parsing no Azure CLI
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tempYaml, $yamlContent, $utf8NoBom)
    
    Write-Host "[INFO] Criando Container App com volume..." -ForegroundColor Cyan
    $ErrorActionPreference = "Continue"
    try {
        az containerapp create `
            --name $QdrantApp `
            --resource-group $ResourceGroup `
            --yaml $tempYaml 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Container App criado com volume" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] Erro ao criar com YAML, tentando sem volume..." -ForegroundColor Yellow
            # Fallback: criar sem volume
            az containerapp create `
                --name $QdrantApp `
                --resource-group $ResourceGroup `
                --environment $Environment `
                --image qdrant/qdrant:v1.7.4 `
                --target-port 6333 `
                --ingress internal `
                --cpu 1.0 `
                --memory 2.0Gi `
                --min-replicas 1 `
                --max-replicas 1 `
                --env-vars "QDRANT__SERVICE__GRPC_PORT=6334" 2>&1 | Out-Null
            Write-Host "[AVISO] Container App criado sem volume. Configure manualmente via portal." -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
    }
    
    $ErrorActionPreference = "Stop"
    Write-Host "[OK] Qdrant Container App criado" -ForegroundColor Green
} else {
    Write-Host "[OK] Qdrant Container App já existe" -ForegroundColor Green
}

Write-Host ""
