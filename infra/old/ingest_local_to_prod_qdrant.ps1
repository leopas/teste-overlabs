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
    # Obter diretório do script para encontrar deploy_state.json relativo ao repositório
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado." -ForegroundColor Red
        Write-Host "[INFO] Forneça -ResourceGroup e -QdrantAppName ou execute do diretório raiz do projeto." -ForegroundColor Yellow
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

# Obter FQDN do Qdrant (precisa ser externo para acesso de fora do Container Apps Environment)
Write-Host "[INFO] Obtendo URL do Qdrant..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$qdrantFqdn = az containerapp show `
    --name $QdrantAppName `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

# Se não tiver FQDN externo, o Qdrant pode estar configurado como interno
# Nesse caso, precisamos usar o FQDN do Environment
if (-not $qdrantFqdn) {
    Write-Host "[AVISO] Qdrant não tem FQDN externo. Obtendo FQDN do Environment..." -ForegroundColor Yellow
    $envName = az containerapp show --name $QdrantAppName --resource-group $ResourceGroup --query "properties.environmentId" -o tsv 2>$null
    if ($envName -match '/managedEnvironments/([^/]+)') {
        $envNameOnly = $matches[1]
        $envFqdn = az containerapp env show --name $envNameOnly --resource-group $ResourceGroup --query "properties.defaultDomain" -o tsv 2>$null
        if ($envFqdn) {
            # Construir URL usando o nome do app e o domínio do environment
            $appNameShort = $QdrantAppName -replace '.*-', ''
            $qdrantFqdn = "$QdrantAppName.$envFqdn"
        }
    }
}

$ErrorActionPreference = "Stop"

if (-not $qdrantFqdn) {
    Write-Host "[ERRO] Não foi possível obter FQDN do Qdrant" -ForegroundColor Red
    Write-Host "[INFO] O Qdrant pode estar configurado como 'internal'. Para ingestão local, ele precisa ter ingress externo." -ForegroundColor Yellow
    exit 1
}

# Garantir que a URL use HTTPS
if (-not $qdrantFqdn.StartsWith("http")) {
    $qdrantUrl = "https://$qdrantFqdn"
} else {
    $qdrantUrl = $qdrantFqdn
}

Write-Host "[OK] Qdrant URL: $qdrantUrl" -ForegroundColor Green
Write-Host ""

# Verificar se documentos locais existem (relativo ao repositório)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$docsFullPath = Join-Path $repoRoot $DocsPath

if (-not (Test-Path $docsFullPath)) {
    Write-Host "[ERRO] Diretório '$docsFullPath' não encontrado!" -ForegroundColor Red
    exit 1
}

# Usar caminho absoluto para os documentos
$DocsPath = $docsFullPath

Write-Host "[OK] Documentos locais encontrados: $DocsPath" -ForegroundColor Green
Write-Host ""

# Carregar OPENAI_API_KEY do .env (no diretório raiz)
$openaiKey = $null
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$envFile = Join-Path $repoRoot ".env"

if (Test-Path $envFile) {
    Write-Host "[INFO] Carregando OPENAI_API_KEY do .env..." -ForegroundColor Yellow
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*OPENAI_API_KEY\s*=\s*(.+)$' -and $_ -notmatch '^\s*#') {
            $openaiKey = $matches[1].Trim('"').Trim("'")
            # Remover comentários inline
            if ($openaiKey -match '^(.+?)\s*#') {
                $openaiKey = $matches[1].Trim()
            }
        }
    }
}

if ($openaiKey) {
    Write-Host "[OK] OPENAI_API_KEY carregada do .env" -ForegroundColor Green
} else {
    # Tentar variável de ambiente como fallback
    $openaiKey = $env:OPENAI_API_KEY
    if ($openaiKey) {
        Write-Host "[OK] OPENAI_API_KEY encontrada nas variáveis de ambiente" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] OPENAI_API_KEY não encontrada no .env nem nas variáveis de ambiente" -ForegroundColor Red
        Write-Host "  Configure no .env ou:" -ForegroundColor Yellow
        Write-Host "  `$env:OPENAI_API_KEY = 'sk-...'" -ForegroundColor Gray
        Write-Host ""
        Write-Host "[INFO] Arquivo .env esperado em: $envFile" -ForegroundColor Cyan
        exit 1
    }
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

# Mudar para o diretório backend para executar os scripts Python
$originalDir = Get-Location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$backendDir = Join-Path $repoRoot "backend"

if (-not (Test-Path $backendDir)) {
    Write-Host "[ERRO] Diretório 'backend' não encontrado!" -ForegroundColor Red
    exit 1
}

Set-Location $backendDir
$env:DOCS_ROOT = (Resolve-Path (Join-Path $originalDir $DocsPath)).Path
$env:PYTHONPATH = $backendDir

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

Set-Location $originalDir

# Executar ingest localmente apontando para Qdrant de produção
Write-Host "[INFO] Executando ingest localmente → Qdrant de produção..." -ForegroundColor Cyan
Write-Host "  Qdrant: $qdrantUrl" -ForegroundColor Gray
Write-Host "  Documentos: $DocsPath" -ForegroundColor Gray
Write-Host "  Embeddings: OpenAI" -ForegroundColor Gray
Write-Host ""

# Mudar para o diretório backend para executar os scripts Python
Set-Location $backendDir

# Configurar variáveis de ambiente para o Python
$env:DOCS_ROOT = (Resolve-Path (Join-Path $originalDir $DocsPath)).Path
$env:QDRANT_URL = $qdrantUrl
$env:USE_OPENAI_EMBEDDINGS = "true"
$env:PYTHONPATH = $backendDir

if ($openaiKey) {
    $env:OPENAI_API_KEY = $openaiKey
}

$ingestOutput = python -m scripts.ingest 2>&1

# Voltar para o diretório original
Set-Location $originalDir

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
