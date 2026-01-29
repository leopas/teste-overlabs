# Script para fazer commit e push de todas as mudanças
# Uso: .\infra\commit_and_push.ps1 -Message "descrição do commit"

param(
    [Parameter(Mandatory=$false)]
    [string]$Message = "chore: atualizar configurações e scripts de infraestrutura",
    
    [switch]$SkipStatus,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Commit e Push de Mudanças ===" -ForegroundColor Cyan
Write-Host ""

# Verificar se estamos em um repositório git
if (-not (Test-Path ".git")) {
    Write-Host "[ERRO] Diretório atual não é um repositório git!" -ForegroundColor Red
    exit 1
}

# Verificar status do git
if (-not $SkipStatus) {
    Write-Host "[INFO] Verificando status do repositório..." -ForegroundColor Yellow
    git status --short
    Write-Host ""
}

# Verificar se há mudanças
$changes = git status --porcelain
if (-not $changes) {
    Write-Host "[AVISO] Nenhuma mudança para commitar" -ForegroundColor Yellow
    exit 0
}

Write-Host "[INFO] Mudanças detectadas:" -ForegroundColor Yellow
git status --short
Write-Host ""

# Adicionar todas as mudanças
Write-Host "[INFO] Adicionando todas as mudanças..." -ForegroundColor Yellow
git add -A

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Falha ao adicionar arquivos" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Arquivos adicionados" -ForegroundColor Green
Write-Host ""

# Fazer commit
Write-Host "[INFO] Fazendo commit..." -ForegroundColor Yellow
Write-Host "  Mensagem: $Message" -ForegroundColor Gray
Write-Host ""

git commit -m $Message

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Falha ao fazer commit" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Commit realizado" -ForegroundColor Green
Write-Host ""

# Verificar branch atual
$currentBranch = git branch --show-current
Write-Host "[INFO] Branch atual: $currentBranch" -ForegroundColor Yellow
Write-Host ""

# Push
Write-Host "[INFO] Fazendo push para origin/$currentBranch..." -ForegroundColor Yellow

if ($Force) {
    Write-Host "[AVISO] Usando --force (perigoso!)" -ForegroundColor Yellow
    git push --force origin $currentBranch
} else {
    git push origin $currentBranch
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Falha ao fazer push" -ForegroundColor Red
    Write-Host "[INFO] Verifique se você tem permissões e se o remote está configurado" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] Push realizado com sucesso!" -ForegroundColor Green
Write-Host ""

# Verificar se há pipeline configurada
$hasWorkflow = Test-Path ".github/workflows"
if ($hasWorkflow) {
    Write-Host "[INFO] Pipeline do GitHub Actions será acionada automaticamente" -ForegroundColor Cyan
    Write-Host "[INFO] Acompanhe em: https://github.com/$(git remote get-url origin | Select-String -Pattern 'github.com[:/](.+?)/(.+?)\.git' | ForEach-Object { $_.Matches[0].Groups[1].Value + '/' + $_.Matches[0].Groups[2].Value })/actions" -ForegroundColor Gray
} else {
    Write-Host "[AVISO] Nenhuma pipeline encontrada em .github/workflows" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host ""
