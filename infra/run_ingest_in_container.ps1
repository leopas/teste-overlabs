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

# Carregar deploy_state.json se não fornecido (relativo ao repositório)
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
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
    
    # Método simples: listar /app e verificar se DOC-IA aparece
    $appList = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "ls /app" 2>&1
    
    if ($appList -match "DOC-IA") {
        Write-Host "[OK] Diretório /app/DOC-IA encontrado no container" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "[ERRO] Diretório /app/DOC-IA não encontrado no container!" -ForegroundColor Red
        Write-Host "[INFO] Saída de 'ls /app': $appList" -ForegroundColor Gray
        Write-Host "[INFO] Verifique se o volume de documentos está montado corretamente." -ForegroundColor Yellow
        Write-Host "[INFO] Execute: .\infra\add_volume_mount.ps1 para adicionar o volume mount" -ForegroundColor Yellow
        exit 1
    }
    $ErrorActionPreference = "Stop"
    Write-Host ""
}

# Verificar configuração de embeddings e QDRANT_URL
Write-Host "[INFO] Verificando configuração..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Carregar env vars do template (inclui value OU secretRef)
$envList = $null
try {
    $envListJson = az containerapp show `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --query "properties.template.containers[0].env" -o json 2>$null
    if ($envListJson) {
        $envList = $envListJson | ConvertFrom-Json
    }
} catch {
    $envList = $null
}

# Verificar QDRANT_URL (usar variável de ambiente do container)
Write-Host "[INFO] Verificando QDRANT_URL..." -ForegroundColor Cyan
# Verificar via az containerapp show (mais confiável que exec)
$envVars = $null
if ($envList) {
    $qdrantEnv = $envList | Where-Object { $_.name -eq "QDRANT_URL" } | Select-Object -First 1
    if ($qdrantEnv) { $envVars = $qdrantEnv.value }
}
if (-not $envVars) {
    # Fallback (formato antigo do script)
    $envVars = az containerapp show `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --query "properties.template.containers[0].env[?name=='QDRANT_URL'].value" -o tsv 2>$null
}

if ($envVars -and $envVars -ne "NOT_SET") {
    Write-Host "[OK] QDRANT_URL configurada: $envVars" -ForegroundColor Green
    
    # Verificar se está usando FQDN interno completo (necessário quando external: false)
    if ($envVars -notmatch "\.internal\." -and $envVars -match "app-overlabs-qdrant-prod-300:6333") {
        Write-Host "[AVISO] QDRANT_URL está usando nome curto. Pode não resolver corretamente!" -ForegroundColor Yellow
        Write-Host "[INFO] Execute: .\infra\fix_qdrant_url.ps1 para corrigir para FQDN interno completo" -ForegroundColor Yellow
        Write-Host ""
    }
} else {
    Write-Host "[ERRO] QDRANT_URL não está configurada no container!" -ForegroundColor Red
    Write-Host "[INFO] Execute o bootstrap novamente ou configure manualmente." -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# Testar conexão com Qdrant (usar módulo Python direto)
Write-Host "[INFO] Testando conexão com Qdrant..." -ForegroundColor Cyan
# Pular teste de conexão por enquanto - será testado durante ingest
Write-Host "[INFO] Teste de conexão será feito durante a ingestão" -ForegroundColor Yellow
Write-Host ""

# Verificar embeddings (usar az containerapp show)
$useOpenAIEnv = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='USE_OPENAI_EMBEDDINGS'].value" -o tsv 2>&1

# Aceitar "true", "1", ou "True"
if ($useOpenAIEnv -eq "true" -or $useOpenAIEnv -eq "1" -or $useOpenAIEnv -eq "True") {
    Write-Host "[OK] USE_OPENAI_EMBEDDINGS está habilitado" -ForegroundColor Green
    
    # Em Azure Container Apps, secrets aparecem como env { name, secretRef } (e NÃO em .value)
    $openaiEnv = $null
    if ($envList) {
        $openaiEnv = $envList | Where-Object { $_.name -eq "OPENAI_API_KEY" } | Select-Object -First 1
    }

    if ($openaiEnv -and $openaiEnv.secretRef) {
        Write-Host "[OK] OPENAI_API_KEY configurada via secretRef: $($openaiEnv.secretRef)" -ForegroundColor Green

        # Verificar se o secretRef existe em properties.configuration.secrets (sem expor valores)
        try {
            $secretsJson = az containerapp show `
                --name $ApiAppName `
                --resource-group $ResourceGroup `
                --query "properties.configuration.secrets" -o json 2>$null
            if ($secretsJson) {
                $secrets = $secretsJson | ConvertFrom-Json
                $ref = $openaiEnv.secretRef
                $foundSecret = $secrets | Where-Object { $_.name -eq $ref } | Select-Object -First 1
                if ($foundSecret) {
                    if ($foundSecret.keyVaultUrl) {
                        $id = $foundSecret.identity
                        if (-not $id) { $id = "(não informado)" }
                        Write-Host "  [OK] Secret '$ref' aponta para Key Vault: $($foundSecret.keyVaultUrl) (identity=$id)" -ForegroundColor Green
                    } else {
                        Write-Host "  [OK] Secret '$ref' existe no Container App (valor não exibido)" -ForegroundColor Green
                    }
                } else {
                    Write-Host "  [AVISO] secretRef '$ref' não foi encontrado em properties.configuration.secrets" -ForegroundColor Yellow
                    Write-Host "  [INFO] Isso costuma causar falha em runtime (env var fica vazia). Reaplique secrets/env do Container App." -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  [AVISO] Não foi possível verificar a lista de secrets do Container App (sem expor valores)." -ForegroundColor Yellow
        }
    } elseif ($openaiEnv -and $openaiEnv.value -and $openaiEnv.value.Length -gt 10) {
        Write-Host "[OK] OPENAI_API_KEY configurada (valor direto)" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] OPENAI_API_KEY não encontrada ou não configurada corretamente" -ForegroundColor Yellow
        Write-Host "[INFO] Em ACA, o esperado é env com secretRef (ex.: OPENAI_API_KEY -> secretRef: openai-api-key) e o secret definido em configuration.secrets." -ForegroundColor Yellow
        Write-Host "[INFO] Se a ingestão falhar com 401, o problema tende a ser resolução do Key Vault (RBAC/identity) ou valor inválido/BOM." -ForegroundColor Gray
    }

    # Teste em runtime: conferir se a env var está realmente presente no container (sem expor o valor)
    Write-Host ""
    Write-Host "[INFO] Testando presença de OPENAI_API_KEY dentro do container (sem expor valor)..." -ForegroundColor Cyan
    try {
        # Evitar sh/base64/pipes/redirecionamento e também aspas duplas aninhadas no Windows.
        # Usar aspas simples no lado do container (shell), e aspas duplas dentro do Python.
        $checkCmd = "python -c 'import os,json; v=os.getenv(""OPENAI_API_KEY"",""""); has_bom=(len(v)>0 and ord(v[0])==65279); print(json.dumps({""present"": bool(v), ""length"": len(v), ""has_bom"": has_bom}))'"

        $ErrorActionPreference = "Continue"
        $checkOut = az containerapp exec `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --command $checkCmd 2>&1
        $ErrorActionPreference = "Stop"

        if ($LASTEXITCODE -eq 0 -and $checkOut) {
            Write-Host "  Resultado: $checkOut" -ForegroundColor Gray
        } else {
            Write-Host "  [AVISO] Não foi possível executar o teste dentro do container (exit=$LASTEXITCODE)." -ForegroundColor Yellow
            if ($checkOut) { Write-Host "  Saída: $checkOut" -ForegroundColor Gray }
        }
    } catch {
        $ErrorActionPreference = "Stop"
        Write-Host "  [AVISO] Falha ao testar OPENAI_API_KEY dentro do container: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[INFO] Usando embeddings locais (FastEmbed)" -ForegroundColor Yellow
    Write-Host "[AVISO] USE_OPENAI_EMBEDDINGS está como: '$useOpenAIEnv'" -ForegroundColor Gray
}
$ErrorActionPreference = "Stop"
Write-Host ""

# Truncar collection se solicitado
if ($TruncateFirst) {
    Write-Host "[INFO] Truncando collection 'docs_chunks'..." -ForegroundColor Cyan
    Write-Host ""
    
    # Método mais simples: usar módulo Python direto via -m
    # Mas como não temos módulo truncate, vamos usar um script inline mais simples
    # Criar script Python usando echo e base64 para evitar problemas de escape
    $truncatePythonScript = @"
import sys
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
    
    # Codificar em base64 e criar comando que decodifica e executa
    $truncateBytes = [System.Text.Encoding]::UTF8.GetBytes($truncatePythonScript)
    $truncateBase64 = [Convert]::ToBase64String($truncateBytes)
    
    # Usar método que funciona: criar arquivo temporário no container via echo + base64
    # Isso evita problemas de escape do PowerShell
    $truncateCmd = "sh -c `"echo '$truncateBase64' | base64 -d > /tmp/truncate.py && python /tmp/truncate.py`""
    
    $ErrorActionPreference = "Continue"
    az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command $truncateCmd 2>&1 | Out-Host
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Collection truncada" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Erro ao truncar collection. Continuando mesmo assim..." -ForegroundColor Yellow
    }
    $ErrorActionPreference = "Stop"
    Write-Host ""
}

# Executar scan_docs (com retry para rate limit)
Write-Host "[INFO] Executando scan_docs no container..." -ForegroundColor Cyan
Write-Host ""

$maxRetries = 3
$retryDelay = 30
$scanSuccess = $false

for ($retry = 1; $retry -le $maxRetries; $retry++) {
    if ($retry -gt 1) {
        Write-Host "[INFO] Tentativa $retry de $maxRetries (aguardando ${retryDelay}s devido a rate limit)..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryDelay
    }
    
    $ErrorActionPreference = "Continue"
    $scanOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -m scripts.scan_docs" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host $scanOutput
        Write-Host "[OK] scan_docs concluído" -ForegroundColor Green
        $scanSuccess = $true
        break
    } elseif ($scanOutput -match "429|Too Many Requests") {
        Write-Host "[AVISO] Rate limit detectado. Aguardando antes de tentar novamente..." -ForegroundColor Yellow
        $retryDelay = [Math]::Min($retryDelay * 2, 120) # Backoff exponencial, max 2 minutos
    } else {
        Write-Host $scanOutput
        Write-Host "[AVISO] scan_docs retornou erro. Continuando mesmo assim..." -ForegroundColor Yellow
        $scanSuccess = $true # Continuar mesmo com erro
        break
    }
    $ErrorActionPreference = "Stop"
}

if (-not $scanSuccess) {
    Write-Host "[AVISO] scan_docs falhou após $maxRetries tentativas. Continuando mesmo assim..." -ForegroundColor Yellow
}
Write-Host ""

# Executar ingest (com retry para rate limit)
Write-Host "[INFO] Executando ingest no container..." -ForegroundColor Cyan
Write-Host "  Isso pode levar alguns minutos dependendo do número de documentos" -ForegroundColor Gray
Write-Host ""

$retryDelay = 30 # Reset delay
$ingestSuccess = $false

for ($retry = 1; $retry -le $maxRetries; $retry++) {
    if ($retry -gt 1) {
        Write-Host "[INFO] Tentativa $retry de $maxRetries (aguardando ${retryDelay}s devido a rate limit)..." -ForegroundColor Yellow
        Start-Sleep -Seconds $retryDelay
    }
    
    $ErrorActionPreference = "Continue"
    $ingestOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -m scripts.ingest" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host $ingestOutput
        Write-Host "[OK] Ingestão concluída com sucesso!" -ForegroundColor Green
        $ingestSuccess = $true
        break
    } elseif ($ingestOutput -match "429|Too Many Requests") {
        Write-Host "[AVISO] Rate limit detectado. Aguardando antes de tentar novamente..." -ForegroundColor Yellow
        $retryDelay = [Math]::Min($retryDelay * 2, 120) # Backoff exponencial, max 2 minutos
    } else {
        Write-Host $ingestOutput
        Write-Host "[ERRO] Ingestão falhou com código $LASTEXITCODE" -ForegroundColor Red
        if ($retry -eq $maxRetries) {
            Write-Host "[INFO] Falhou após $maxRetries tentativas. Verifique os logs do container." -ForegroundColor Yellow
            exit 1
        }
    }
    $ErrorActionPreference = "Stop"
}

if (-not $ingestSuccess) {
    Write-Host "[ERRO] Ingestão falhou após $maxRetries tentativas devido a rate limits." -ForegroundColor Red
    Write-Host "[INFO] Aguarde alguns minutos e tente novamente, ou execute os comandos manualmente:" -ForegroundColor Yellow
    Write-Host "  az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command 'python -m scripts.ingest'" -ForegroundColor Gray
    exit 1
}
Write-Host ""

# Verificar documentos indexados (pular se ingestão falhou ou rate limit)
Write-Host "[INFO] Verificando documentos indexados..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Aguardar um pouco antes de verificar (evitar rate limit)
Start-Sleep -Seconds 15

# Evitar sh/base64/pipes/redirecionamento no Windows: usar python -c direto
$checkCmd = "python -c 'from qdrant_client import QdrantClient; import os; q=QdrantClient(url=os.getenv(""QDRANT_URL""), timeout=30.0); info=q.get_collection(""docs_chunks""); print(""Pontos indexados: "" + str(info.points_count))'"

$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command $checkCmd 2>&1

if ($checkOutput -match "429|Too Many Requests") {
    Write-Host "[AVISO] Rate limit ao verificar pontos. Pule esta verificação." -ForegroundColor Yellow
} else {
    Write-Host $checkOutput
}
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Ingestão Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Testar a API com uma pergunta para verificar se os documentos foram indexados corretamente" -ForegroundColor Gray
Write-Host "  2. Verificar logs do Container App se houver problemas" -ForegroundColor Gray
Write-Host ""
