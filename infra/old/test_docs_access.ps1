# Script simples para testar acesso a /app/DOC-IA

$rg = "rg-overlabs-prod"
$app = "app-overlabs-prod-300"

Write-Host "=== Teste de Acesso a /app/DOC-IA ===" -ForegroundColor Cyan
Write-Host ""

# Teste 1: Listar /app
Write-Host "[TESTE 1] Listando /app..." -ForegroundColor Yellow
az containerapp exec --name $app --resource-group $rg --command "ls /app" 2>&1
Write-Host ""

# Teste 2: Verificar se DOC-IA existe
Write-Host "[TESTE 2] Verificando se /app/DOC-IA existe..." -ForegroundColor Yellow
$testScript = 'import os; print("EXISTS" if os.path.isdir("/app/DOC-IA") else "NOT_FOUND")'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($testScript)
$base64 = [Convert]::ToBase64String($bytes)

az containerapp exec --name $app --resource-group $rg --command "python -c `"import base64; exec(base64.b64decode('$base64').decode('utf-8'))\`"" 2>&1
Write-Host ""

# Teste 3: Listar arquivos em DOC-IA
Write-Host "[TESTE 3] Listando arquivos em /app/DOC-IA..." -ForegroundColor Yellow
$listScript = 'import os; files = os.listdir("/app/DOC-IA"); print(f"Total: {len(files)}"); [print(f) for f in sorted(files)]'
$bytes2 = [System.Text.Encoding]::UTF8.GetBytes($listScript)
$base642 = [Convert]::ToBase64String($bytes2)

az containerapp exec --name $app --resource-group $rg --command "python -c `"import base64; exec(base64.b64decode('$base642').decode('utf-8'))\`"" 2>&1
Write-Host ""
