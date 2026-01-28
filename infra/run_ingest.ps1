# Script para executar ingestão de documentos no Container App de produção
# Uso: .\infra\run_ingest.ps1

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

Write-Host "=== Executar Ingestão de Documentos ===" -ForegroundColor Cyan
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

# Verificar se os documentos estão disponíveis
Write-Host "[INFO] Verificando se DOCS_ROOT está configurado..." -ForegroundColor Yellow
$envVars = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
$docsRoot = ($envVars | Where-Object { $_.name -eq "DOCS_ROOT" }).value

if (-not $docsRoot) {
    Write-Host "[AVISO] DOCS_ROOT não encontrado nas variáveis de ambiente" -ForegroundColor Yellow
    Write-Host "  O script de ingestão usará o padrão: /docs" -ForegroundColor Gray
    $docsRoot = "/docs"
} else {
    Write-Host "[OK] DOCS_ROOT configurado: $docsRoot" -ForegroundColor Green
}
Write-Host ""

# Executar scan_docs primeiro
Write-Host "[INFO] Executando scan_docs para gerar layout_report.md..." -ForegroundColor Cyan
Write-Host "  Isso analisa os documentos e gera um relatório de layout" -ForegroundColor Gray
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

# Executar ingest
Write-Host "[INFO] Executando ingest para indexar documentos no Qdrant..." -ForegroundColor Cyan
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
Write-Host "=== Ingestão Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Testar a API com uma pergunta para verificar se os documentos foram indexados" -ForegroundColor Gray
Write-Host "  2. Verificar logs do Container App se houver problemas" -ForegroundColor Gray
Write-Host ""
