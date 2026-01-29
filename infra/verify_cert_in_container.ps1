# Script para verificar se o certificado MySQL existe no container e corrigir se necessario

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiAppName = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Verificacao de Certificado MySQL no Container ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verificar variável MYSQL_SSL_CA
Write-Host "[1/3] Verificando variavel MYSQL_SSL_CA..." -ForegroundColor Yellow
$envVars = az containerapp show `
    --name $ApiAppName `
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
    Write-Host "  [OK] MYSQL_SSL_CA: $mysqlSslCa" -ForegroundColor Green
} else {
    Write-Host "  [ERRO] MYSQL_SSL_CA nao encontrada!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# 2. Verificar se o arquivo existe no container
Write-Host "[2/3] Verificando se o certificado existe no container..." -ForegroundColor Yellow

$checkScript = @'
import os
import sys

cert_path = os.getenv('MYSQL_SSL_CA', '/app/certs/DigiCertGlobalRootCA.crt.pem')
print(f'Verificando: {cert_path}')

if os.path.exists(cert_path):
    size = os.path.getsize(cert_path)
    print(f'EXISTS:{size}')
    with open(cert_path, 'r') as f:
        first_line = f.readline().strip()
        print(f'FIRST_LINE:{first_line}')
else:
    print('NOT_FOUND')
    # Verificar se o diretorio existe
    cert_dir = os.path.dirname(cert_path)
    if os.path.exists(cert_dir):
        print(f'DIR_EXISTS:{cert_dir}')
        files = os.listdir(cert_dir)
        print(f'FILES_IN_DIR:{",".join(files)}')
    else:
        print(f'DIR_NOT_FOUND:{cert_dir}')
'@

$b64Script = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($checkScript))

$ErrorActionPreference = "Continue"
$checkOutput = az containerapp exec `
    --name $ApiAppName `
    --resource-group $ResourceGroup `
    --command "python -c `"import base64, sys; exec(base64.b64decode('$b64Script').decode('utf-8'))`"" 2>&1
$ErrorActionPreference = "Stop"

# Filtrar linhas de log do Azure CLI
$cleanOutput = $checkOutput | Where-Object { 
    $_ -notmatch "WARNING|INFO|Connecting|Successfully|Disconnecting|received|Use ctrl" 
}

if ($cleanOutput -match "EXISTS:") {
    $size = ($cleanOutput | Select-String "EXISTS:(\d+)").Matches[0].Groups[1].Value
    $firstLine = ($cleanOutput | Select-String "FIRST_LINE:(.+)").Matches[0].Groups[1].Value
    Write-Host "  [OK] Certificado encontrado!" -ForegroundColor Green
    Write-Host "    Tamanho: $size bytes" -ForegroundColor Gray
    Write-Host "    Primeira linha: $firstLine" -ForegroundColor Gray
    
    if ($firstLine -match "BEGIN CERTIFICATE") {
        Write-Host "  [OK] Certificado parece valido" -ForegroundColor Green
    } else {
        Write-Host "  [AVISO] Certificado pode estar corrompido" -ForegroundColor Yellow
    }
} elseif ($cleanOutput -match "NOT_FOUND") {
    Write-Host "  [ERRO] Certificado NAO encontrado no container!" -ForegroundColor Red
    
    if ($cleanOutput -match "DIR_EXISTS:") {
        $dirPath = ($cleanOutput | Select-String "DIR_EXISTS:(.+)").Matches[0].Groups[1].Value
        $files = ($cleanOutput | Select-String "FILES_IN_DIR:(.+)").Matches[0].Groups[1].Value
        Write-Host "    Diretorio existe: $dirPath" -ForegroundColor Gray
        Write-Host "    Arquivos no diretorio: $files" -ForegroundColor Gray
    } else {
        Write-Host "    Diretorio do certificado tambem nao existe!" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "  [INFO] Solucao:" -ForegroundColor Cyan
    Write-Host "    1. Verifique se o certificado esta na pasta certs/ localmente" -ForegroundColor Gray
    Write-Host "    2. Rebuild da imagem Docker para incluir o certificado" -ForegroundColor Gray
    Write-Host "    3. Ou baixe o certificado diretamente no container (temporario)" -ForegroundColor Gray
} else {
    Write-Host "  [AVISO] Nao foi possivel verificar (container pode nao estar rodando)" -ForegroundColor Yellow
    Write-Host $cleanOutput
}
Write-Host ""

# 3. Se nao encontrado, tentar baixar diretamente no container
if ($cleanOutput -match "NOT_FOUND") {
    Write-Host "[3/3] Tentando baixar certificado diretamente no container..." -ForegroundColor Yellow
    
    $downloadScript = @'
import os
import urllib.request

cert_path = os.getenv('MYSQL_SSL_CA', '/app/certs/DigiCertGlobalRootCA.crt.pem')
cert_dir = os.path.dirname(cert_path)

# Criar diretorio se nao existir
os.makedirs(cert_dir, exist_ok=True)

# Baixar certificado
cert_url = 'https://cacerts.digicert.com/DigiCertGlobalRootCA.crt.pem'
try:
    urllib.request.urlretrieve(cert_url, cert_path)
    print(f'DOWNLOADED:{cert_path}')
    size = os.path.getsize(cert_path)
    print(f'SIZE:{size}')
except Exception as e:
    print(f'ERROR:{str(e)}')
'@
    
    $b64Download = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($downloadScript))
    
    $ErrorActionPreference = "Continue"
    $downloadOutput = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python -c `"import base64, sys; exec(base64.b64decode('$b64Download').decode('utf-8'))`"" 2>&1
    $ErrorActionPreference = "Stop"
    
    $cleanDownload = $downloadOutput | Where-Object { 
        $_ -notmatch "WARNING|INFO|Connecting|Successfully|Disconnecting|received|Use ctrl" 
    }
    
    if ($cleanDownload -match "DOWNLOADED:") {
        $size = ($cleanDownload | Select-String "SIZE:(\d+)").Matches[0].Groups[1].Value
        Write-Host "  [OK] Certificado baixado com sucesso!" -ForegroundColor Green
        Write-Host "    Tamanho: $size bytes" -ForegroundColor Gray
        Write-Host "  [AVISO] Esta e uma solucao temporaria. Rebuild a imagem Docker para incluir o certificado permanentemente." -ForegroundColor Yellow
    } elseif ($cleanDownload -match "ERROR:") {
        $error = ($cleanDownload | Select-String "ERROR:(.+)").Matches[0].Groups[1].Value
        Write-Host "  [ERRO] Falha ao baixar certificado: $error" -ForegroundColor Red
    } else {
        Write-Host "  [AVISO] Nao foi possivel baixar o certificado" -ForegroundColor Yellow
    }
} else {
    Write-Host "[3/3] Certificado ja existe, pulando download" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Verificacao Concluida ===" -ForegroundColor Cyan
Write-Host ""
