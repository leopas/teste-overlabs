# Script para executar ingestão dentro do container da API
# Usa os documentos já montados em /app/DOC-IA e acessa Qdrant interno

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [switch]$TruncateFirst,
    [switch]$VerifyDocs
)

$ErrorActionPreference = "Stop"

Write-Host "=== Executar Ingestão no Container da API ===" -ForegroundColor Cyan
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
Write-Host "[INFO] API Container App: $ApiAppName" -ForegroundColor Yellow
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

# Verificar se /app/DOC-IA existe no container
if ($VerifyDocs -or $true) {
    Write-Host "[INFO] Verificando se /app/DOC-IA existe no container..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    $docsCheck = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_FOUND'" 2>&1
    
    if ($docsCheck -match "EXISTS") {
        Write-Host "[OK] Diretório /app/DOC-IA encontrado no container" -ForegroundColor Green
        
        # Listar arquivos
        Write-Host "[INFO] Listando arquivos em /app/DOC-IA..." -ForegroundColor Yellow
        az containerapp exec `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --command "ls -la /app/DOC-IA | head -20" 2>&1 | Out-Host
        Write-Host ""
    } else {
        Write-Host "[ERRO] Diretório /app/DOC-IA não encontrado no container!" -ForegroundColor Red
        Write-Host "[INFO] Verifique se o volume de documentos está montado corretamente." -ForegroundColor Yellow
        Write-Host "[INFO] Execute: .\infra\bootstrap_container_apps.ps1 para configurar o volume." -ForegroundColor Yellow
        exit 1
    }
    $ErrorActionPreference = "Stop"
    Write-Host ""
}

# Verificar configuração de embeddings e QDRANT_URL
Write-Host "[INFO] Verificando configuração..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Verificar QDRANT_URL
Write-Host "[INFO] Verificando QDRANT_URL..." -ForegroundColor Cyan
$qdrantUrlCheck = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c 'import os; url = os.getenv(\"QDRANT_URL\", \"NOT_SET\"); print(f\"QDRANT_URL={url}\")'" 2>&1

Write-Host $qdrantUrlCheck
if ($qdrantUrlCheck -match "NOT_SET" -or -not $qdrantUrlCheck) {
    Write-Host "[ERRO] QDRANT_URL não está configurada no container!" -ForegroundColor Red
    Write-Host "[INFO] Execute o bootstrap novamente ou configure manualmente." -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# Testar conexão com Qdrant
Write-Host "[INFO] Testando conexão com Qdrant..." -ForegroundColor Cyan
$testConnection = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"from qdrant_client import QdrantClient; from app.config import settings; import sys; try: qdrant = QdrantClient(url=settings.qdrant_url, timeout=10.0); collections = qdrant.get_collections(); print(f'[OK] Conectado ao Qdrant: {settings.qdrant_url}'); print(f'[OK] Collections encontradas: {len(collections.collections)}'); sys.exit(0); except Exception as e: print(f'[ERRO] Falha ao conectar: {e}'); import traceback; traceback.print_exc(); sys.exit(1)\`"" 2>&1

Write-Host $testConnection
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Não foi possível conectar ao Qdrant!" -ForegroundColor Red
    Write-Host "[INFO] Verifique se o Qdrant Container App está rodando e se a URL está correta." -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# Verificar embeddings
$useOpenAI = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c 'import os; print(\"true\" if os.getenv(\"USE_OPENAI_EMBEDDINGS\", \"false\").lower() == \"true\" else \"false\")'" 2>&1 | Select-String -Pattern "true|false"

if ($useOpenAI -match "true") {
    Write-Host "[OK] USE_OPENAI_EMBEDDINGS está habilitado" -ForegroundColor Green
    
    $hasKey = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -c 'import os; print(\"true\" if os.getenv(\"OPENAI_API_KEY\") else \"false\")'" 2>&1 | Select-String -Pattern "true|false"
    
    if ($hasKey -match "true") {
        Write-Host "[OK] OPENAI_API_KEY configurada" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] OPENAI_API_KEY não encontrada no container" -ForegroundColor Yellow
        Write-Host "[INFO] Configure no Key Vault e referencie no Container App." -ForegroundColor Yellow
    }
} else {
    Write-Host "[INFO] Usando embeddings locais (FastEmbed)" -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"
Write-Host ""

# Truncar collection se solicitado
if ($TruncateFirst) {
    Write-Host "[INFO] Truncando collection 'docs_chunks'..." -ForegroundColor Cyan
    Write-Host ""
    
    # Executar truncate usando Python inline (mais confiável que arquivo)
    $truncateScript = @"
import sys
from pathlib import Path
sys.path.insert(0, '/app')
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm
from app.config import settings

collection_name = 'docs_chunks'
try:
    qdrant = QdrantClient(url=settings.qdrant_url, timeout=30.0)
    try:
        info = qdrant.get_collection(collection_name)
        print(f'[INFO] Collection existe com {info.points_count} pontos')
        all_ids = []
        offset = None
        while True:
            result = qdrant.scroll(collection_name=collection_name, limit=1000, offset=offset, with_payload=False, with_vectors=False)
            points, next_offset = result
            if not points: break
            all_ids.extend([p.id for p in points])
            if next_offset is None: break
            offset = next_offset
        if all_ids:
            print(f'[INFO] Deletando {len(all_ids)} pontos...')
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
            raise
except Exception as e:
    print(f'[ERRO] Falha: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
"@
    
    $ErrorActionPreference = "Continue"
    az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -c `"$($truncateScript -replace '"', '\"')`"" 2>&1 | Out-Host
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Collection truncada" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Erro ao truncar collection. Continuando mesmo assim..." -ForegroundColor Yellow
    }
    $ErrorActionPreference = "Stop"
    Write-Host ""
}

# Executar scan_docs
Write-Host "[INFO] Executando scan_docs no container..." -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Continue"
az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -m scripts.scan_docs" 2>&1 | Out-Host

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] scan_docs concluído" -ForegroundColor Green
} else {
    Write-Host "[AVISO] scan_docs retornou erro. Continuando mesmo assim..." -ForegroundColor Yellow
}
$ErrorActionPreference = "Stop"
Write-Host ""

# Executar ingest
Write-Host "[INFO] Executando ingest no container..." -ForegroundColor Cyan
Write-Host "  Isso pode levar alguns minutos dependendo do número de documentos" -ForegroundColor Gray
Write-Host ""

$ErrorActionPreference = "Continue"
az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -m scripts.ingest" 2>&1 | Out-Host

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Ingestão concluída com sucesso!" -ForegroundColor Green
} else {
    Write-Host "[ERRO] Ingestão falhou com código $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"
Write-Host ""

# Verificar documentos indexados
Write-Host "[INFO] Verificando documentos indexados..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"from qdrant_client import QdrantClient; import os; qdrant = QdrantClient(url=os.getenv('QDRANT_URL')); info = qdrant.get_collection('docs_chunks'); print(f'Pontos indexados: {info.points_count}')\`"" 2>&1 | Out-Host
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Ingestão Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Testar a API com uma pergunta para verificar se os documentos foram indexados corretamente" -ForegroundColor Gray
Write-Host "  2. Verificar logs do Container App se houver problemas" -ForegroundColor Gray
Write-Host ""
