# Testar conectividade com Qdrant e corrigir URL se necessário

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiAppName = "app-overlabs-prod-300",
    [string]$QdrantAppName = "app-overlabs-qdrant-prod-300"
)

Write-Host "=== Testar Conectividade com Qdrant ===" -ForegroundColor Cyan
Write-Host ""

# Obter URL atual configurada
$currentUrl = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='QDRANT_URL'].value" -o tsv 2>$null

Write-Host "[INFO] URL atual configurada: $currentUrl" -ForegroundColor Yellow

# Obter FQDN interno do Qdrant
$qdrantFqdn = az containerapp show `
    --name $QdrantAppName `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

Write-Host "[INFO] FQDN interno do Qdrant: $qdrantFqdn" -ForegroundColor Yellow
Write-Host ""

# Criar script Python para testar ambas as URLs
$testScript = @"
import os
import httpx
import sys

urls_to_test = [
    os.getenv('QDRANT_URL', ''),
    'http://app-overlabs-qdrant-prod-300:6333',
    'http://$qdrantFqdn:6333'
]

print('[INFO] Testando conectividade com Qdrant...')
print('')

for url in urls_to_test:
    if not url:
        continue
    try:
        print(f'Testando: {url}')
        r = httpx.get(f'{url}/healthz', timeout=10.0)
        print(f'  [OK] Status: {r.status_code}')
        print(f'  [OK] URL funcionando: {url}')
        sys.exit(0)
    except Exception as e:
        print(f'  [ERRO] Falha: {e}')
        print('')

print('[ERRO] Nenhuma URL funcionou!')
sys.exit(1)
"@

# Salvar script temporário
$tempScript = [System.IO.Path]::GetTempFileName() + ".py"
$testScript | Out-File -FilePath $tempScript -Encoding utf8

try {
    # Copiar script para o container e executar
    Write-Host "[INFO] Testando conectividade..." -ForegroundColor Cyan
    
    # Usar az containerapp exec com arquivo Python
    $testOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python $tempScript" 2>&1
    
    Write-Host $testOutput
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[OK] Conectividade OK!" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "[ERRO] Falha na conectividade!" -ForegroundColor Red
        Write-Host "[INFO] Pode ser necessário atualizar a URL do Qdrant para o FQDN interno" -ForegroundColor Yellow
    }
} finally {
    # Limpar arquivo temporário
    if (Test-Path $tempScript) {
        Remove-Item $tempScript -Force
    }
}

Write-Host ""
Write-Host "=== Fim do Teste ===" -ForegroundColor Cyan
