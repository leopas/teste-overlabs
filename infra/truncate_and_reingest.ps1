# Script para truncar a collection do Qdrant em produção e reindexar com OpenAI embeddings
# Uso: .\infra\truncate_and_reingest.ps1
# 
# NOTA: Se DOCS_ROOT não existir no container, execute primeiro:
#   .\infra\verify_and_fix_docs.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null,
    [string]$CollectionName = "docs_chunks",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Truncar Collection e Reindexar com OpenAI ===" -ForegroundColor Cyan
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

# Verificar variáveis de ambiente
Write-Host "[INFO] Verificando configuração..." -ForegroundColor Yellow
$envVars = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json

$useOpenAI = ($envVars | Where-Object { $_.name -eq "USE_OPENAI_EMBEDDINGS" }).value
$openAIKey = ($envVars | Where-Object { $_.name -eq "OPENAI_API_KEY" }).value

if (-not $useOpenAI -or ($useOpenAI -ne "true" -and $useOpenAI -ne "True" -and $useOpenAI -ne "1")) {
    Write-Host "[AVISO] USE_OPENAI_EMBEDDINGS não está habilitado!" -ForegroundColor Yellow
    Write-Host "  Configurando USE_OPENAI_EMBEDDINGS=true..." -ForegroundColor Cyan
    
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --set-env-vars "USE_OPENAI_EMBEDDINGS=true" 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] USE_OPENAI_EMBEDDINGS habilitado" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao habilitar USE_OPENAI_EMBEDDINGS" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] USE_OPENAI_EMBEDDINGS já está habilitado" -ForegroundColor Green
}

if (-not $openAIKey) {
    Write-Host "[ERRO] OPENAI_API_KEY não está configurada!" -ForegroundColor Red
    Write-Host "  Configure a chave antes de continuar:" -ForegroundColor Yellow
    Write-Host "  .\infra\add_single_env_var.ps1 -VarName 'OPENAI_API_KEY' -VarValue 'sk-...'" -ForegroundColor Gray
    exit 1
} else {
    Write-Host "[OK] OPENAI_API_KEY configurada" -ForegroundColor Green
}

$docsRoot = ($envVars | Where-Object { $_.name -eq "DOCS_ROOT" }).value
if (-not $docsRoot) {
    Write-Host "[AVISO] DOCS_ROOT não encontrado, configurando para: /app/DOC-IA" -ForegroundColor Yellow
    $docsRoot = "/app/DOC-IA"
    
    # Configurar DOCS_ROOT
    Write-Host "  Configurando DOCS_ROOT no Container App..." -ForegroundColor Cyan
    $ErrorActionPreference = "Continue"
    az containerapp update `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --set-env-vars "DOCS_ROOT=/app/DOC-IA" 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] DOCS_ROOT configurado para /app/DOC-IA" -ForegroundColor Green
        Write-Host "  Aguardando 10s para a atualização ser aplicada..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        
        # Verificar se foi realmente configurado
        $envVarsCheck = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
        $docsRootCheck = ($envVarsCheck | Where-Object { $_.name -eq "DOCS_ROOT" }).value
        if ($docsRootCheck -eq "/app/DOC-IA") {
            Write-Host "[OK] DOCS_ROOT confirmado: $docsRootCheck" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] DOCS_ROOT pode não ter sido aplicado ainda. Continuando..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[ERRO] Falha ao configurar DOCS_ROOT" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] DOCS_ROOT configurado: $docsRoot" -ForegroundColor Green
    if ($docsRoot -ne "/app/DOC-IA") {
        Write-Host "[AVISO] DOCS_ROOT está configurado como '$docsRoot', mas os documentos estão em /app/DOC-IA" -ForegroundColor Yellow
        Write-Host "  Considerando atualizar DOCS_ROOT para /app/DOC-IA..." -ForegroundColor Yellow
    }
}

Write-Host ""

# Verificar se /app/DOC-IA existe no container
Write-Host "[INFO] Verificando se /app/DOC-IA existe no container..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$checkDocsOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1

if ($checkDocsOutput -match "NOT_EXISTS" -or $checkDocsOutput -notmatch "EXISTS") {
    Write-Host "[AVISO] /app/DOC-IA não existe no container!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Os documentos precisam ser copiados para o container primeiro." -ForegroundColor Yellow
    Write-Host "  Execute:" -ForegroundColor Yellow
    Write-Host "    .\infra\verify_and_fix_docs.ps1" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Ou faça um novo build da imagem Docker com os documentos incluídos." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "[OK] /app/DOC-IA existe no container" -ForegroundColor Green
Write-Host ""

# Confirmação
if (-not $Force) {
    Write-Host "[AVISO] Esta operação irá:" -ForegroundColor Yellow
    Write-Host "  1. Truncar (limpar todos os pontos) da collection '$CollectionName' do Qdrant" -ForegroundColor Red
    Write-Host "  2. Reindexar todos os documentos de $docsRoot usando OpenAI embeddings" -ForegroundColor Yellow
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

# Passo 1: Truncar a collection (deletar todos os pontos)
Write-Host "[INFO] Passo 1/3: Truncando collection '$CollectionName' (deletando todos os pontos)..." -ForegroundColor Cyan
Write-Host ""

# Verificar se o script Python existe localmente e copiá-lo, ou executar inline
$truncateScriptPath = "infra/scripts/truncate_collection.py"
if (Test-Path $truncateScriptPath) {
    # Ler o script e executar no container
    $scriptContent = Get-Content $truncateScriptPath -Raw -Encoding utf8
    
    # Criar comando Python inline que executa o script
    $pythonCommand = "python -c `"$($scriptContent -replace '"', '\"')`" $CollectionName"
    
    $ErrorActionPreference = "Continue"
    $truncateOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command $pythonCommand 2>&1
} else {
    # Fallback: executar script Python inline simples
    $inlineScript = @"
import sys
from pathlib import Path
sys.path.insert(0, str(Path('/app')))
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm
from app.config import settings

collection_name = '$CollectionName'
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
            print(f'[INFO] Collection já está vazia')
    except Exception as e:
        if '404' in str(e) or 'not found' in str(e).lower():
            print(f'[AVISO] Collection não existe. Será criada durante a ingestão.')
        else:
            raise
except Exception as e:
    print(f'[ERRO] Falha: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
"@
    
    $ErrorActionPreference = "Continue"
    $truncateOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -c `"$($inlineScript -replace '"', '\"')`"" 2>&1
}

if ($LASTEXITCODE -eq 0) {
    Write-Host $truncateOutput
    Write-Host "[OK] Collection truncada" -ForegroundColor Green
} else {
    Write-Host "[AVISO] Erro ao truncar collection (pode não existir):" -ForegroundColor Yellow
    Write-Host $truncateOutput
    Write-Host "  Continuando com ingestão..." -ForegroundColor Gray
}
Write-Host ""

# Passo 2: Executar scan_docs
Write-Host "[INFO] Passo 2/3: Executando scan_docs para gerar layout_report.md..." -ForegroundColor Cyan
Write-Host "  DOCS_ROOT: $docsRoot" -ForegroundColor Gray
Write-Host ""

# Aguardar um pouco para garantir que a atualização do DOCS_ROOT foi aplicada
Start-Sleep -Seconds 5

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

# Passo 3: Executar ingest (vai usar OpenAI embeddings se USE_OPENAI_EMBEDDINGS=true)
Write-Host "[INFO] Passo 3/3: Executando ingest para indexar documentos com OpenAI embeddings..." -ForegroundColor Cyan
Write-Host "  Isso pode levar alguns minutos dependendo do número de documentos" -ForegroundColor Gray
Write-Host "  Usando embeddador: OpenAI (text-embedding-3-small)" -ForegroundColor Gray
Write-Host "  DOCS_ROOT: $docsRoot" -ForegroundColor Gray
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

# Verificar se a ingestão realmente funcionou
Write-Host ""
Write-Host "[INFO] Verificando se documentos foram indexados..." -ForegroundColor Yellow

# Usar comando Python inline simples (uma linha)
$verifyCommand = "python -c `"import sys; sys.path.insert(0, '/app'); from qdrant_client import QdrantClient; from app.config import settings; qdrant = QdrantClient(url=settings.qdrant_url, timeout=10.0); info = qdrant.get_collection('$CollectionName'); print(f'[OK] Collection tem {info.points_count} pontos indexados'); print('[OK] Ingestão bem-sucedida!' if info.points_count > 0 else '[AVISO] Collection está vazia')`""

$ErrorActionPreference = "Continue"
$verifyOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command $verifyCommand 2>&1

Write-Host $verifyOutput
Write-Host ""

Write-Host "=== Reindexação Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Testar a API com uma pergunta para verificar se os documentos foram indexados corretamente" -ForegroundColor Gray
Write-Host "  2. Verificar logs do Container App se houver problemas" -ForegroundColor Gray
Write-Host "  3. Verificar se os embeddings estão usando OpenAI (dimensão deve ser 1536 para text-embedding-3-small)" -ForegroundColor Gray
Write-Host ""
