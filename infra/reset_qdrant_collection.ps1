# Script para dropar e recriar a collection do Qdrant em produção
# Uso: .\infra\reset_qdrant_collection.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$CollectionName = "docs_chunks",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Reset da Collection do Qdrant ===" -ForegroundColor Cyan
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
Write-Host "[INFO] Collection: $CollectionName" -ForegroundColor Yellow
Write-Host ""

# Verificar se Container App existe
Write-Host "[INFO] Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$appExists = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $appExists) {
    Write-Host "[ERRO] Container App '$ApiAppName' não encontrado no Resource Group '$ResourceGroup'" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# Confirmação
if (-not $Force) {
    Write-Host "[AVISO] Esta operação irá:" -ForegroundColor Yellow
    Write-Host "  1. Deletar a collection '$CollectionName' do Qdrant" -ForegroundColor Red
    Write-Host "  2. Recriar a collection" -ForegroundColor Yellow
    Write-Host "  3. Reindexar todos os documentos" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ⚠️  ATENÇÃO: Todos os dados indexados serão perdidos!" -ForegroundColor Red
    Write-Host ""
    $confirmation = Read-Host "Digite 'SIM' para confirmar"
    if ($confirmation -ne "SIM") {
        Write-Host "[INFO] Operação cancelada." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""

# Passo 1: Dropar a collection
Write-Host "[INFO] Passo 1/3: Deletando collection '$CollectionName'..." -ForegroundColor Cyan
Write-Host ""

$dropScript = @"
import sys
from pathlib import Path
sys.path.insert(0, str(Path('/app')))
from qdrant_client import QdrantClient
from app.config import settings

try:
    qdrant = QdrantClient(url=settings.qdrant_url, timeout=10.0)
    qdrant.delete_collection('$CollectionName')
    print(f'[OK] Collection \"$CollectionName\" deletada com sucesso')
except Exception as e:
    error_msg = str(e)
    if '404' in error_msg or 'not found' in error_msg.lower():
        print(f'[AVISO] Collection \"$CollectionName\" não existe (já foi deletada ou nunca existiu)')
    else:
        print(f'[ERRO] Falha ao deletar collection: {error_msg}')
        sys.exit(1)
"@

$ErrorActionPreference = "Continue"
$dropOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"$dropScript`"" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host $dropOutput
    Write-Host "[OK] Collection deletada" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Erro ao deletar collection (pode não existir):" -ForegroundColor Yellow
    Write-Host $dropOutput
    Write-Host "  Continuando com recriação..." -ForegroundColor Gray
}
Write-Host ""

# Passo 2: Executar scan_docs
Write-Host "[INFO] Passo 2/3: Executando scan_docs para gerar layout_report.md..." -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Continue"
$scanOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -m scripts.scan_docs" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] scan_docs concluído" -ForegroundColor Green
    Write-Host $scanOutput
} else {
    Write-Host "[AVISO] scan_docs retornou código $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host $scanOutput
    Write-Host "  Continuando com ingestão mesmo assim..." -ForegroundColor Gray
}
Write-Host ""

# Passo 3: Executar ingest (vai recriar a collection automaticamente)
Write-Host "[INFO] Passo 3/3: Executando ingest para recriar collection e indexar documentos..." -ForegroundColor Cyan
Write-Host "  Isso pode levar alguns minutos dependendo do número de documentos" -ForegroundColor Gray
Write-Host ""

$ErrorActionPreference = "Continue"
$ingestOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -m scripts.ingest" 2>&1

$ErrorActionPreference = "Stop"

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Ingestão concluída com sucesso!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Saída:" -ForegroundColor Cyan
    Write-Host $ingestOutput
} else {
    Write-Host "[ERRO] Ingestão falhou com código $LASTEXITCODE" -ForegroundColor Red
    Write-Host ""
    Write-Host "Saída:" -ForegroundColor Yellow
    Write-Host $ingestOutput
    exit 1
}

Write-Host ""
Write-Host "=== Reset Concluído! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Testar a API com uma pergunta para verificar se os documentos foram indexados corretamente" -ForegroundColor Gray
Write-Host "  2. Verificar logs do Container App se houver problemas" -ForegroundColor Gray
Write-Host ""
