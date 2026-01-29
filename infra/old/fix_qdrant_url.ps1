# Corrigir URL do Qdrant para usar FQDN interno completo

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiAppName = "app-overlabs-prod-300",
    [string]$QdrantAppName = "app-overlabs-qdrant-prod-300"
)

Write-Host "=== Corrigir URL do Qdrant ===" -ForegroundColor Cyan
Write-Host ""

# Obter FQDN interno do Qdrant
Write-Host "[INFO] Obtendo FQDN interno do Qdrant..." -ForegroundColor Yellow
$qdrantFqdn = az containerapp show `
    --name $QdrantAppName `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

if (-not $qdrantFqdn) {
    Write-Host "[ERRO] Falha ao obter FQDN do Qdrant!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] FQDN interno: $qdrantFqdn" -ForegroundColor Green

# Verificar URL atual
$currentUrl = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='QDRANT_URL'].value" -o tsv 2>$null

Write-Host "[INFO] URL atual: $currentUrl" -ForegroundColor Yellow

# Construir nova URL com FQDN
$newUrl = "http://${qdrantFqdn}:6333"

if ($currentUrl -eq $newUrl) {
    Write-Host "[OK] URL já está correta!" -ForegroundColor Green
    exit 0
}

Write-Host "[INFO] Nova URL: $newUrl" -ForegroundColor Cyan
Write-Host ""

# Confirmar atualização
Write-Host "[INFO] Atualizando QDRANT_URL no Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Método 1: Tentar com --set-env-vars (mais simples)
Write-Host "[INFO] Tentando atualizar via --set-env-vars..." -ForegroundColor Cyan
$updateOutput = az containerapp update `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --set-env-vars "QDRANT_URL=$newUrl" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] URL atualizada com sucesso!" -ForegroundColor Green
} else {
    # Método 2: Exportar YAML, editar e reaplicar
    Write-Host "[AVISO] Método 1 falhou. Tentando via YAML..." -ForegroundColor Yellow
    
    $tempYaml = [System.IO.Path]::GetTempFileName() + ".yaml"
    
    try {
        # Exportar YAML atual
        Write-Host "[INFO] Exportando configuração atual..." -ForegroundColor Cyan
        az containerapp show `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            -o yaml | Out-File -FilePath $tempYaml -Encoding utf8
        
        # Ler YAML e substituir QDRANT_URL
        $yamlContent = Get-Content $tempYaml -Raw
        $yamlContent = $yamlContent -replace "value:\s*http://app-overlabs-qdrant-prod-300:6333", "value: $newUrl"
        $yamlContent = $yamlContent -replace "value:\s*http://app-overlabs-qdrant-prod-300\.internal[^\s]*:6333", "value: $newUrl"
        
        # Salvar YAML modificado
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tempYaml, $yamlContent, $utf8NoBom)
        
        # Aplicar YAML
        Write-Host "[INFO] Aplicando YAML modificado..." -ForegroundColor Cyan
        az containerapp update `
            --name $ApiAppName `
            --resource-group $ResourceGroup `
            --yaml $tempYaml 2>&1 | Out-Host
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] URL atualizada via YAML!" -ForegroundColor Green
        } else {
            Write-Host "[ERRO] Falha ao atualizar via YAML também!" -ForegroundColor Red
            Write-Host "[INFO] YAML salvo em: $tempYaml para inspeção manual" -ForegroundColor Yellow
            exit 1
        }
    } finally {
        # Limpar arquivo temporário após alguns segundos
        Start-Sleep -Seconds 2
        if (Test-Path $tempYaml) {
            Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "[INFO] Aguardando nova revision ficar pronta..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# Verificar nova revision
$latestRevision = az containerapp revision list `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null

Write-Host "[OK] Nova revision: $latestRevision" -ForegroundColor Green

# Verificar se a URL foi realmente atualizada
$updatedUrl = az containerapp show `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env[?name=='QDRANT_URL'].value" -o tsv 2>$null

if ($updatedUrl -eq $newUrl) {
    Write-Host "[OK] URL confirmada: $updatedUrl" -ForegroundColor Green
} else {
    Write-Host "[AVISO] URL pode não ter sido atualizada corretamente" -ForegroundColor Yellow
    Write-Host "[INFO] URL atual: $updatedUrl" -ForegroundColor Yellow
    Write-Host "[INFO] URL esperada: $newUrl" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Correção Concluída! ===" -ForegroundColor Green
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Cyan
Write-Host "  1. Aguarde alguns minutos para a revision ficar totalmente pronta"
Write-Host "  2. Execute novamente: .\infra\run_ingest_in_container.ps1 -TruncateFirst"
