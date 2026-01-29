# Script para verificar e corrigir o diretório DOC-IA no container
# Copia os documentos locais (DOC-IA/) para /app/DOC-IA no container
# Uso: .\infra\verify_and_fix_docs.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificar e Corrigir DOC-IA no Container ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $ApiAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -ApiAppName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $ApiAppName) {
        $ApiAppName = $state.apiAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ApiAppName" -ForegroundColor Yellow
Write-Host ""

# Verificar se DOC-IA existe localmente
$localDocsPath = "DOC-IA"
if (-not (Test-Path $localDocsPath)) {
    Write-Host "[ERRO] Diretório local '$localDocsPath' não encontrado!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Diretório local '$localDocsPath' encontrado" -ForegroundColor Green
Write-Host ""

# Verificar o que há em /app no container
Write-Host "[INFO] Verificando conteúdo de /app no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$listOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "ls -la /app" 2>&1

Write-Host $listOutput
Write-Host ""

# Verificar se /app/DOC-IA existe
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1

if ($checkOutput -match "EXISTS") {
    Write-Host "[OK] /app/DOC-IA existe no container" -ForegroundColor Green
    
    # Listar conteúdo
    Write-Host "[INFO] Listando conteúdo de /app/DOC-IA..." -ForegroundColor Yellow
    $listDocsOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "ls -la /app/DOC-IA" 2>&1
    Write-Host $listDocsOutput
    Write-Host ""
    Write-Host "=== Verificação Concluída ===" -ForegroundColor Green
    exit 0
}

Write-Host "[AVISO] /app/DOC-IA não existe no container" -ForegroundColor Yellow
Write-Host ""

# Criar diretório e copiar arquivos
Write-Host "[INFO] Criando /app/DOC-IA e copiando documentos..." -ForegroundColor Cyan
Write-Host ""

# Criar diretório
az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "mkdir -p /app/DOC-IA" 2>&1 | Out-Null

# Copiar cada arquivo individualmente
$docFiles = Get-ChildItem -Path $localDocsPath -File -Recurse
$copiedCount = 0

foreach ($file in $docFiles) {
    $relativePath = $file.FullName.Replace((Resolve-Path $localDocsPath).Path + "\", "").Replace("\", "/")
    $containerPath = "/app/DOC-IA/$relativePath"
    $containerDir = Split-Path $containerPath -Parent
    
    Write-Host "  Copiando: $relativePath" -ForegroundColor Gray
    
    # Criar diretório se necessário
    az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "mkdir -p `"$containerDir`"" 2>&1 | Out-Null
    
    # Usar base64 para copiar arquivo (mais confiável que echo)
    $fileBytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $base64Content = [Convert]::ToBase64String($fileBytes)
    
    # Criar comando Python para escrever arquivo
    $pythonCommand = @"
import base64
import os
content = base64.b64decode('$base64Content')
os.makedirs(os.path.dirname('$containerPath'), exist_ok=True)
with open('$containerPath', 'wb') as f:
    f.write(content)
print('OK')
"@
    
    $ErrorActionPreference = "Continue"
    $copyOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -c `"$($pythonCommand -replace '"', '\"')`"" 2>&1
    
    if ($LASTEXITCODE -eq 0 -and $copyOutput -match "OK") {
        $copiedCount++
    } else {
        Write-Host "    [AVISO] Erro ao copiar $relativePath" -ForegroundColor Yellow
        Write-Host "    Saída: $copyOutput" -ForegroundColor Gray
    }
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "[OK] $copiedCount arquivo(s) copiado(s)" -ForegroundColor Green
Write-Host ""

# Verificar novamente
Write-Host "[INFO] Verificando novamente..." -ForegroundColor Yellow
$verifyOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "ls -la /app/DOC-IA" 2>&1

Write-Host $verifyOutput
Write-Host ""

Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Agora você pode executar:" -ForegroundColor Yellow
Write-Host "  .\infra\truncate_and_reingest.ps1" -ForegroundColor Gray
Write-Host ""
