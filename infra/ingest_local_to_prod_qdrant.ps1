# Script para executar ingestão localmente apontando para Qdrant de produção
# Uso: .\infra\ingest_local_to_prod_qdrant.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$QdrantAppName = $null,
    [string]$DocsPath = "DOC-IA",
    [switch]$TruncateFirst
)

$ErrorActionPreference = "Stop"

Write-Host "=== Ingestão Local → Qdrant de Produção ===" -ForegroundColor Cyan
Write-Host ""

# Carregar deploy_state.json se não fornecido
if (-not $ResourceGroup -or -not $QdrantAppName) {
    $stateFile = ".azure/deploy_state.json"
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado. Forneça -ResourceGroup e -QdrantAppName." -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $stateFile | ConvertFrom-Json
    if (-not $ResourceGroup) {
        $ResourceGroup = $state.resourceGroup
    }
    if (-not $QdrantAppName) {
        $QdrantAppName = $state.qdrantAppName
    }
}

Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Qdrant Container App: $QdrantAppName" -ForegroundColor Yellow
Write-Host "[INFO] Documentos locais: $DocsPath" -ForegroundColor Yellow
Write-Host ""

# Verificar se Qdrant Container App existe
Write-Host "[INFO] Verificando Qdrant Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$qdrantExists = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "name" -o tsv 2>$null
$ErrorActionPreference = "Stop"

if (-not $qdrantExists) {
    Write-Host "[ERRO] Qdrant Container App '$QdrantAppName' não encontrado" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Qdrant Container App encontrado" -ForegroundColor Green
Write-Host ""

# Obter FQDN do Qdrant
Write-Host "[INFO] Obtendo URL do Qdrant..." -ForegroundColor Yellow
$qdrantFqdn = az containerapp show `
    --name $QdrantAppName `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv

if (-not $qdrantFqdn) {
    Write-Host "[ERRO] Não foi possível obter FQDN do Qdrant" -ForegroundColor Red
    exit 1
}

$qdrantUrl = "https://$qdrantFqdn"
Write-Host "[OK] Qdrant URL: $qdrantUrl" -ForegroundColor Green
Write-Host ""

# Verificar se documentos locais existem
if (-not (Test-Path $DocsPath)) {
    Write-Host "[ERRO] Diretório '$DocsPath' não encontrado!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Documentos locais encontrados: $DocsPath" -ForegroundColor Green
Write-Host ""

# Verificar se OPENAI_API_KEY está configurada
$openaiKey = $env:OPENAI_API_KEY
if (-not $openaiKey) {
    Write-Host "[AVISO] OPENAI_API_KEY não encontrada nas variáveis de ambiente" -ForegroundColor Yellow
    Write-Host "  Configure antes de continuar:" -ForegroundColor Yellow
    Write-Host "  `$env:OPENAI_API_KEY = 'sk-...'" -ForegroundColor Gray
    Write-Host ""
    $continue = Read-Host "Deseja continuar mesmo assim? (S/N)"
    if ($continue -ne "S" -and $continue -ne "s") {
        exit 0
    }
} else {
    Write-Host "[OK] OPENAI_API_KEY configurada" -ForegroundColor Green
}
Write-Host ""

# Truncar collection se solicitado
if ($TruncateFirst) {
    Write-Host "[INFO] Truncando collection 'docs_chunks'..." -ForegroundColor Cyan
    
    $truncateScript = @"
import sys
from qdrant_client import QdrantClient

qdrant = QdrantClient(url='$qdrantUrl', timeout=30.0)
collection_name = 'docs_chunks'

try:
    info = qdrant.get_collection(collection_name)
    print(f'[INFO] Collection existe com {info.points_count} pontos')
    
    # Coletar todos os IDs
    all_ids = []
    offset = None
    while True:
        result = qdrant.scroll(collection_name=collection_name, limit=1000, offset=offset, with_payload=False, with_vectors=False)
        points, next_offset = result
        if not points:
            break
        all_ids.extend([p.id for p in points])
        if next_offset is None:
            break
        offset = next_offset
    
    if all_ids:
        print(f'[INFO] Deletando {len(all_ids)} pontos...')
        from qdrant_client.http import models as qm
        for i in range(0, len(all_ids), 1000):
            batch = all_ids[i:i+1000]
            qdrant.delete(collection_name=collection_name, points_selector=qm.PointIdsList(points=batch))
            print(f'  Deletados {min(i+1000, len(all_ids))}/{len(all_ids)} pontos...')
        print(f'[OK] Collection truncada ({len(all_ids)} pontos removidos)')
    else:
        print('[INFO] Collection já está vazia')
except Exception as e:
    if '404' in str(e) or 'not found' in str(e).lower():
        print('[AVISO] Collection não existe. Será criada durante a ingestão.')
    else:
        print(f'[ERRO] Falha: {e}')
        sys.exit(1)
"@
    
    python -c $truncateScript
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[AVISO] Erro ao truncar collection. Continuando mesmo assim..." -ForegroundColor Yellow
    }
    Write-Host ""
}

# Executar scan_docs localmente
Write-Host "[INFO] Executando scan_docs localmente..." -ForegroundColor Cyan
Write-Host ""

$env:DOCS_ROOT = $DocsPath
$scanOutput = python -m scripts.scan_docs 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] scan_docs concluído" -ForegroundColor Green
    Write-Host $scanOutput
} else {
    Write-Host "[AVISO] scan_docs retornou código $LASTEXITCODE" -ForegroundColor Yellow
    Write-Host $scanOutput
    Write-Host "  Continuando com ingestão mesmo assim..." -ForegroundColor Gray
}
Write-Host ""

# Executar ingest localmente apontando para Qdrant de produção
Write-Host "[INFO] Executando ingest localmente → Qdrant de produção..." -ForegroundColor Cyan
Write-Host "  Qdrant: $qdrantUrl" -ForegroundColor Gray
Write-Host "  Documentos: $DocsPath" -ForegroundColor Gray
Write-Host "  Embeddings: OpenAI" -ForegroundColor Gray
Write-Host ""

# Configurar variáveis de ambiente para o Python
$env:DOCS_ROOT = $DocsPath
$env:QDRANT_URL = $qdrantUrl
$env:USE_OPENAI_EMBEDDINGS = "true"

if ($openaiKey) {
    $env:OPENAI_API_KEY = $openaiKey
}

$ingestOutput = python -m scripts.ingest 2>&1

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
Write-Host "=== Ingestão Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Documentos foram indexados no Qdrant de produção:" -ForegroundColor Yellow
Write-Host "  URL: $qdrantUrl" -ForegroundColor Gray
Write-Host "  Collection: docs_chunks" -ForegroundColor Gray
Write-Host ""
