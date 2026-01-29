# Script simples para verificar se o certificado existe no container

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiApp = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificando Certificado no Container ===" -ForegroundColor Cyan
Write-Host ""

$certPath = "/app/certs/DigiCertGlobalRootCA.crt.pem"

Write-Host "Verificando: $certPath" -ForegroundColor Yellow
Write-Host ""

# Usar cat para ler o arquivo (se existir) ou mostrar erro
$result = az containerapp exec `
    --name $ApiApp `
    --resource-group $ResourceGroup `
    --command "test -f $certPath && echo 'EXISTS' && cat $certPath | head -c 200 || echo 'NOT_FOUND'" 2>&1

# Filtrar linhas de log do Azure CLI
$cleanResult = $result | Where-Object { 
    $_ -notmatch "WARNING|INFO|Connecting|Successfully|Disconnecting|received|Use ctrl" 
}

if ($cleanResult -match "EXISTS") {
    Write-Host "[OK] Certificado encontrado!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Primeiros 200 caracteres:" -ForegroundColor Cyan
    $content = ($cleanResult | Where-Object { $_ -notmatch "EXISTS" }) -join "`n"
    Write-Host $content -ForegroundColor Gray
} elseif ($cleanResult -match "NOT_FOUND") {
    Write-Host "[ERRO] Certificado NÃO encontrado no container" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Certificado não foi copiado durante o build" -ForegroundColor Cyan
    Write-Host "  2. Pasta certs/ está vazia no momento do build" -ForegroundColor Cyan
    Write-Host "  3. Dockerfile não está copiando corretamente" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Solução:" -ForegroundColor Yellow
    Write-Host "  1. Execute: .\azure\download-mysql-cert.ps1" -ForegroundColor Cyan
    Write-Host "  2. Rebuild da imagem Docker" -ForegroundColor Cyan
} else {
    Write-Host "[AVISO] Não foi possível verificar (container pode não estar rodando)" -ForegroundColor Yellow
    Write-Host $cleanResult
}
