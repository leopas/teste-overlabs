# Script para verificar se o certificado MySQL está correto no container
# Compara o certificado local, no container e a variável de ambiente

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiApp = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificação de Certificado MySQL ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar certificado local
Write-Host "[1/4] Verificando certificado local..." -ForegroundColor Yellow
$localCertPath = "certs\DigiCertGlobalRootCA.crt.pem"
if (Test-Path $localCertPath) {
    $localCert = Get-Content $localCertPath -Raw
    $localCertSize = (Get-Item $localCertPath).Length
    Write-Host "  [OK] Certificado local encontrado: $localCertPath" -ForegroundColor Green
    Write-Host "       Tamanho: $localCertSize bytes" -ForegroundColor Cyan
    Write-Host "       Primeiros 100 chars: $($localCert.Substring(0, [Math]::Min(100, $localCert.Length)))..." -ForegroundColor Gray
} else {
    Write-Host "  [ERRO] Certificado local NAO encontrado: $localCertPath" -ForegroundColor Red
    Write-Host "         Execute: .\azure\download-mysql-cert.ps1" -ForegroundColor Yellow
    exit 1
}

Write-Host ""

# 2. Verificar variável de ambiente MYSQL_SSL_CA no Container App
Write-Host "[2/4] Verificando variável MYSQL_SSL_CA no Container App..." -ForegroundColor Yellow
$envVars = az containerapp show `
    --name $ApiApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[0].env" `
    -o json | ConvertFrom-Json

$mysqlSslCa = $null
foreach ($env in $envVars) {
    if ($env.name -eq "MYSQL_SSL_CA") {
        $mysqlSslCa = $env.value
        break
    }
}

if ($mysqlSslCa) {
    Write-Host "  [OK] MYSQL_SSL_CA encontrada" -ForegroundColor Green
    Write-Host "       Valor: $mysqlSslCa" -ForegroundColor Cyan
    
    # Verificar se é um caminho ou conteúdo
    if ($mysqlSslCa -match "^/") {
        Write-Host "       Tipo: Caminho de arquivo" -ForegroundColor Gray
    } else {
        Write-Host "       Tipo: Conteúdo do certificado (primeiros 100 chars)" -ForegroundColor Gray
        Write-Host "       $($mysqlSslCa.Substring(0, [Math]::Min(100, $mysqlSslCa.Length)))..." -ForegroundColor Gray
    }
} else {
    Write-Host "  [ERRO] MYSQL_SSL_CA não encontrada no Container App" -ForegroundColor Red
    exit 1
}

Write-Host ""

# 3. Verificar se o certificado existe no container
Write-Host "[3/4] Verificando certificado no container..." -ForegroundColor Yellow

# Se MYSQL_SSL_CA é um caminho, verificar se o arquivo existe
if ($mysqlSslCa -match "^/") {
    $certPath = $mysqlSslCa
    Write-Host "  Verificando arquivo: $certPath" -ForegroundColor Cyan
    
    $checkCertCmd = @"
import os
import sys
cert_path = '$certPath'
if os.path.exists(cert_path):
    with open(cert_path, 'r') as f:
        content = f.read()
    print(f'[OK] Arquivo existe: {cert_path}')
    print(f'Tamanho: {len(content)} bytes')
    print(f'Primeiros 100 chars: {content[:100]}...')
    sys.exit(0)
else:
    print(f'[ERRO] Arquivo NAO existe: {cert_path}')
    sys.exit(1)
"@
    
    $base64Cmd = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($checkCertCmd))
    
    $result = az containerapp exec `
        --name $ApiApp `
        --resource-group $ResourceGroup `
        --command "python -c `"import base64, sys; exec(base64.b64decode('$base64Cmd').decode('utf-8'))`"" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host $result
        $containerCertExists = $true
    } else {
        Write-Host "  [ERRO] Erro ao verificar certificado no container" -ForegroundColor Red
        Write-Host $result
        $containerCertExists = $false
    }
} else {
    Write-Host "  [AVISO] MYSQL_SSL_CA contém o certificado diretamente (não é um caminho)" -ForegroundColor Yellow
    $containerCertExists = $null
}

Write-Host ""

# 4. Comparar conteúdos
Write-Host "[4/4] Comparando conteúdos..." -ForegroundColor Yellow

if ($mysqlSslCa -match "^/") {
    # Se é um caminho, ler o arquivo do container
    $readCertCmd = @"
import os
import sys
cert_path = '$mysqlSslCa'
try:
    with open(cert_path, 'r') as f:
        content = f.read()
    print(content)
    sys.exit(0)
except Exception as e:
    print(f'ERRO: {e}', file=sys.stderr)
    sys.exit(1)
"@
    
    $base64Read = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($readCertCmd))
    $containerCertContent = az containerapp exec `
        --name $ApiApp `
        --resource-group $ResourceGroup `
        --command "python -c `"import base64, sys; exec(base64.b64decode('$base64Read').decode('utf-8'))`"" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $containerCert = $containerCertContent | Where-Object { $_ -notmatch "WARNING|INFO|Connecting|Successfully|Disconnecting|received" } | Out-String
        $containerCert = $containerCert.Trim()
    } else {
        Write-Host "  [ERRO] Não foi possível ler o certificado do container" -ForegroundColor Red
        $containerCert = $null
    }
} else {
    # Se é conteúdo direto, usar o valor da variável
    $containerCert = $mysqlSslCa
}

if ($containerCert) {
    # Normalizar (remover espaços em branco extras)
    $localCertNormalized = $localCert -replace '\r\n', '\n' -replace '\r', '\n'
    $containerCertNormalized = $containerCert -replace '\r\n', '\n' -replace '\r', '\n'
    
    if ($localCertNormalized.Trim() -eq $containerCertNormalized.Trim()) {
        Write-Host "  [OK] Certificados são IDÊNTICOS" -ForegroundColor Green
    } else {
        Write-Host "  [ERRO] Certificados são DIFERENTES" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Comparação:" -ForegroundColor Yellow
        Write-Host "    Local:    $($localCertNormalized.Length) chars" -ForegroundColor Cyan
        Write-Host "    Container: $($containerCertNormalized.Length) chars" -ForegroundColor Cyan
        
        # Mostrar diferenças
        if ($localCertNormalized.Length -ne $containerCertNormalized.Length) {
            Write-Host "    Diferença de tamanho: $([Math]::Abs($localCertNormalized.Length - $containerCertNormalized.Length)) chars" -ForegroundColor Red
        }
        
        # Comparar primeiros caracteres diferentes
        $minLen = [Math]::Min($localCertNormalized.Length, $containerCertNormalized.Length)
        for ($i = 0; $i -lt $minLen; $i++) {
            if ($localCertNormalized[$i] -ne $containerCertNormalized[$i]) {
                Write-Host "    Primeira diferença na posição $i" -ForegroundColor Red
                Write-Host "      Local:    '$($localCertNormalized.Substring([Math]::Max(0, $i-10), [Math]::Min(20, $localCertNormalized.Length - [Math]::Max(0, $i-10))))'" -ForegroundColor Gray
                Write-Host "      Container: '$($containerCertNormalized.Substring([Math]::Max(0, $i-10), [Math]::Min(20, $containerCertNormalized.Length - [Math]::Max(0, $i-10))))'" -ForegroundColor Gray
                break
            }
        }
    }
} else {
    Write-Host "  [ERRO] Não foi possível comparar (certificado do container não disponível)" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Resumo ===" -ForegroundColor Cyan
Write-Host "  Certificado local: $(if (Test-Path $localCertPath) { '[OK]' } else { '[ERRO]' })" -ForegroundColor $(if (Test-Path $localCertPath) { 'Green' } else { 'Red' })
Write-Host "  MYSQL_SSL_CA no Container App: $(if ($mysqlSslCa) { '[OK]' } else { '[ERRO]' })" -ForegroundColor $(if ($mysqlSslCa) { 'Green' } else { 'Red' })
Write-Host "  Certificado no container: $(if ($containerCertExists -ne $null) { if ($containerCertExists) { '[OK]' } else { '[ERRO]' } } else { '[N/A]' })" -ForegroundColor $(if ($containerCertExists -eq $true) { 'Green' } elseif ($containerCertExists -eq $false) { 'Red' } else { 'Yellow' })
Write-Host "  Conteúdo idêntico: $(if ($containerCert -and ($localCertNormalized.Trim() -eq $containerCertNormalized.Trim())) { '[OK]' } else { '[ERRO]' })" -ForegroundColor $(if ($containerCert -and ($localCertNormalized.Trim() -eq $containerCertNormalized.Trim())) { 'Green' } else { 'Red' })
