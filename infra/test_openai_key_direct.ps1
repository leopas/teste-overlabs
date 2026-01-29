# Teste direto da OPENAI_API_KEY no container usando método mais simples

param(
    [string]$ResourceGroup = $null,
    [string]$ApiAppName = $null
)

$ErrorActionPreference = "Stop"

# Carregar deploy_state.json
if (-not $ResourceGroup -or -not $ApiAppName) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptDir
    $stateFile = Join-Path $repoRoot ".azure\deploy_state.json"
    
    if (-not (Test-Path $stateFile)) {
        Write-Host "[ERRO] Arquivo $stateFile não encontrado." -ForegroundColor Red
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

Write-Host "=== Teste Direto: OPENAI_API_KEY ===" -ForegroundColor Cyan
Write-Host ""

# Criar script Python temporário no container
$testScript = @'
import os
import sys

key = os.getenv('OPENAI_API_KEY', 'NOT_SET')

if key == 'NOT_SET':
    print('ERRO: OPENAI_API_KEY não encontrada')
    print('Variável não está definida ou não foi resolvida')
    sys.exit(1)

print(f'OK: Variável encontrada')
print(f'Length: {len(key)}')
print(f'Starts with sk-: {key.startswith("sk-")}')
print(f'First 15 chars: {key[:15]}...')

# Testar chamada real
try:
    import httpx
    response = httpx.get(
        'https://api.openai.com/v1/models',
        headers={'Authorization': f'Bearer {key}'},
        timeout=10.0
    )
    if response.status_code == 200:
        print('OK: API OpenAI respondeu com sucesso!')
        sys.exit(0)
    else:
        print(f'ERRO: API retornou status {response.status_code}')
        print(f'Resposta: {response.text[:200]}')
        sys.exit(1)
except Exception as e:
    print(f'ERRO: Falha ao chamar API: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
'@

# Salvar script localmente temporariamente
$tempScript = [System.IO.Path]::GetTempFileName() + ".py"
$testScript | Out-File -FilePath $tempScript -Encoding utf8 -NoNewline

try {
    Write-Host "[INFO] Criando script Python no container..." -ForegroundColor Yellow
    
    # Copiar script para o container usando base64
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($testScript)
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    
    # Criar script no container
    $createCmd = "python -c `"import base64; f=open('/tmp/test_key.py','w'); f.write(base64.b64decode('$scriptBase64').decode('utf-8')); f.close()\`""
    
    $ErrorActionPreference = "Continue"
    az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command $createCmd 2>&1 | Out-Null
    
    Write-Host "[INFO] Executando teste..." -ForegroundColor Yellow
    Write-Host ""
    
    # Executar script
    $result = az containerapp exec `
        --name $ApiAppName `
        --resource-group $ResourceGroup `
        --command "python /tmp/test_key.py" 2>&1
    
    Write-Host $result
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[OK] OPENAI_API_KEY está funcionando corretamente!" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "[ERRO] OPENAI_API_KEY não está funcionando!" -ForegroundColor Red
        exit 1
    }
} finally {
    if (Test-Path $tempScript) {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }
    $ErrorActionPreference = "Stop"
}

Write-Host ""
