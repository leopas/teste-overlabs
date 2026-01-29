# Script para verificar se Key Vault reference foi resolvida

$rg = "rg-overlabs-prod"
$app = "app-overlabs-prod-248"

Write-Host "=== Verificando Resolucao do Key Vault ===" -ForegroundColor Cyan
Write-Host ""

# Script Python muito simples
$simpleTest = 'import os; k=os.getenv("OPENAI_API_KEY","NOT_SET"); print("LEN:",len(k) if k!="NOT_SET" else 0); print("PREVIEW:",k[:50] if k!="NOT_SET" else "NOT_SET"); print("IS_KV_REF:",k.startswith("@") if k!="NOT_SET" else False); exit(0 if k!="NOT_SET" and not k.startswith("@") else 1)'

Write-Host "[INFO] Testando resolucao..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"
$output = az containerapp exec --name $app --resource-group $rg --command "python -c `"$simpleTest`"" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

Write-Host $output
Write-Host ""

if ($exitCode -eq 0) {
    if ($output -match "IS_KV_REF:\s*False") {
        Write-Host "[OK] Key Vault reference foi RESOLVIDA!" -ForegroundColor Green
        Write-Host "[OK] O container consegue acessar o Key Vault!" -ForegroundColor Green
    } elseif ($output -match "IS_KV_REF:\s*True") {
        Write-Host "[ERRO] Key Vault reference NAO foi resolvida!" -ForegroundColor Red
        Write-Host "[INFO] A referencia ainda esta no formato @Microsoft.KeyVault(...)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "[POSSIVEIS CAUSAS]:" -ForegroundColor Yellow
        Write-Host "  1. Permissoes ainda nao propagaram (aguarde mais 1-2 minutos)" -ForegroundColor Gray
        Write-Host "  2. Managed Identity nao esta sendo usada corretamente" -ForegroundColor Gray
        Write-Host "  3. Key Vault reference precisa ser recriada" -ForegroundColor Gray
    } else {
        Write-Host "[AVISO] Nao foi possivel determinar o status" -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERRO] Falha ao executar teste" -ForegroundColor Red
    Write-Host "[INFO] Saida: $output" -ForegroundColor Gray
}
