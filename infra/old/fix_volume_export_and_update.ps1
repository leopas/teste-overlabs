# Script para corrigir volume mount usando o método recomendado pela Microsoft:
# Exportar YAML completo → Editar → Reaplicar
# 
# Uso: .\infra\fix_volume_export_and_update.ps1 -ResourceGroup "rg-overlabs-prod" -ContainerApp "app-overlabs-prod-300"
#
# Este script implementa a solução "Microsoft-approved" para atualizar volume mounts:
# 1. Atualiza CLI/extensão containerapp
# 2. Exporta o YAML completo do Container App existente
# 3. Edita o YAML exportado adicionando volumeMounts e volumes
# 4. Reaplica com --revision-suffix para forçar nova revision
# 5. Valida o resultado

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ContainerApp = "app-overlabs-prod-300",
    [string]$VolumeName = "docs",
    [string]$MountPath = "/app/DOC-IA",
    [string]$StorageName = "documents-storage",
    [string]$RevisionSuffix = "docsfix",
    [switch]$SkipCliUpdate = $false
)

$ErrorActionPreference = "Stop"

Write-Host "=== Corrigir Volume Mount (Método Export → Editar → Update) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "[INFO] Container App: $ContainerApp" -ForegroundColor Yellow
Write-Host "[INFO] Volume Name: $VolumeName" -ForegroundColor Yellow
Write-Host "[INFO] Mount Path: $MountPath" -ForegroundColor Yellow
Write-Host "[INFO] Storage Name: $StorageName" -ForegroundColor Yellow
Write-Host ""

# 1. Atualizar CLI/extensão (elimina variável de versão)
if (-not $SkipCliUpdate) {
    Write-Host "[INFO] Passo 1/5: Atualizando Azure CLI e extensão containerapp..." -ForegroundColor Yellow
    try {
        az upgrade --yes 2>&1 | Out-Null
        az extension add -n containerapp --upgrade 2>&1 | Out-Null
        Write-Host "[OK] CLI e extensão atualizados" -ForegroundColor Green
    } catch {
        Write-Host "[AVISO] Erro ao atualizar CLI (continuando mesmo assim): $_" -ForegroundColor Yellow
    }
    Write-Host ""
} else {
    Write-Host "[INFO] Passo 1/5: Pulando atualização do CLI (--SkipCliUpdate)" -ForegroundColor Yellow
    Write-Host ""
}

# 2. Verificar se Container App existe
Write-Host "[INFO] Passo 2/5: Verificando Container App..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"
$null = az containerapp show --name $ContainerApp --resource-group $ResourceGroup 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERRO] Container App '$ContainerApp' não encontrado!" -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Stop"
Write-Host "[OK] Container App encontrado" -ForegroundColor Green
Write-Host ""

# 3. Verificar nome do container
Write-Host "[INFO] Passo 3/5: Identificando nome do container..." -ForegroundColor Yellow
$containerNames = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[].name" -o json | ConvertFrom-Json

if ($containerNames.Count -eq 0) {
    Write-Host "[ERRO] Nenhum container encontrado no Container App!" -ForegroundColor Red
    exit 1
}

$containerName = $containerNames[0]
Write-Host "[OK] Container encontrado: '$containerName'" -ForegroundColor Green
Write-Host ""

# 4. Exportar YAML completo do app
Write-Host "[INFO] Passo 4/5: Exportando YAML completo do Container App..." -ForegroundColor Yellow
$yamlFile = [System.IO.Path]::GetTempFileName() + ".yaml"
$yamlFileBackup = $yamlFile + ".backup"

try {
    az containerapp show `
        --name $ContainerApp `
        --resource-group $ResourceGroup `
        -o yaml | Out-File -FilePath $yamlFile -Encoding utf8 -NoNewline
    
    if (-not (Test-Path $yamlFile) -or (Get-Item $yamlFile).Length -eq 0) {
        Write-Host "[ERRO] Falha ao exportar YAML!" -ForegroundColor Red
        exit 1
    }
    
    # Backup do YAML original
    Copy-Item $yamlFile $yamlFileBackup
    Write-Host "[OK] YAML exportado: $yamlFile" -ForegroundColor Green
    Write-Host "[OK] Backup criado: $yamlFileBackup" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "[ERRO] Falha ao exportar YAML: $_" -ForegroundColor Red
    exit 1
}

# 5. Ler e editar YAML
Write-Host "[INFO] Passo 5/5: Editando YAML para adicionar volume mount..." -ForegroundColor Yellow

$yamlContent = Get-Content $yamlFile -Raw

# Verificar se volume mount já existe
if ($yamlContent -match "volumeMounts:") {
    Write-Host "[AVISO] YAML já contém 'volumeMounts'. Verificando se está correto..." -ForegroundColor Yellow
    
    # Verificar se o mount correto já existe
    if ($yamlContent -match "volumeName:\s*$VolumeName" -and $yamlContent -match "mountPath:\s*$MountPath") {
        Write-Host "[OK] Volume mount já está configurado corretamente!" -ForegroundColor Green
        Write-Host "[INFO] YAML mantido em: $yamlFile para inspeção" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "=== Concluído! ===" -ForegroundColor Green
        Write-Host "[INFO] Execute manualmente para aplicar:" -ForegroundColor Cyan
        Write-Host "  az containerapp update -g $ResourceGroup -n $ContainerApp --yaml $yamlFile --revision-suffix $RevisionSuffix" -ForegroundColor Gray
        exit 0
    } else {
        Write-Host "[AVISO] Volume mount existe mas não está correto. Será sobrescrito." -ForegroundColor Yellow
    }
}

# Carregar YAML como objeto (usando PowerShell nativo)
# Nota: PowerShell não tem parser YAML nativo, então vamos fazer edição de string cuidadosa

# Verificar se volumes já existe no template
$hasVolumes = $yamlContent -match "volumes:" -and $yamlContent -match "template:"
$hasVolumeMounts = $yamlContent -match "volumeMounts:" -and $yamlContent -match "name:\s*$containerName"

# Estratégia: encontrar o container pelo nome e adicionar volumeMounts
# E encontrar template e adicionar volumes se não existir

# Adicionar volumeMounts no container
if (-not $hasVolumeMounts) {
    # Procurar pelo container pelo nome
    $containerPattern = "(?s)(\s+- name:\s+$containerName.*?)(\s+resources:|\s+env:|\s*$)"
    if ($yamlContent -match $containerPattern) {
        $containerMatch = $matches[1]
        # Adicionar volumeMounts antes de resources ou env
        $volumeMountYaml = @"

      volumeMounts:
      - volumeName: $VolumeName
        mountPath: $MountPath
"@
        # Inserir volumeMounts antes de resources ou env
        if ($containerMatch -match "resources:") {
            $yamlContent = $yamlContent -replace "(\s+- name:\s+$containerName.*?)(\s+resources:)", "`$1$volumeMountYaml`$2"
        } elseif ($containerMatch -match "env:") {
            $yamlContent = $yamlContent -replace "(\s+- name:\s+$containerName.*?env:.*?)(\s+resources:)", "`$1$volumeMountYaml`$2"
        } else {
            # Adicionar antes do final do container
            $yamlContent = $yamlContent -replace "(\s+- name:\s+$containerName.*?)(\s+resources:|\s*$)", "`$1$volumeMountYaml`$2"
        }
        Write-Host "[OK] volumeMounts adicionado ao container '$containerName'" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Não foi possível encontrar container '$containerName' no YAML!" -ForegroundColor Red
        Write-Host "[INFO] YAML exportado mantido em: $yamlFile para inspeção manual" -ForegroundColor Cyan
        exit 1
    }
} else {
    Write-Host "[OK] volumeMounts já existe no YAML" -ForegroundColor Green
}

# Adicionar volumes no template se não existir
if (-not $hasVolumes) {
    # Procurar por "scale:" ou final do template para adicionar volumes
    $volumesYaml = @"
    volumes:
    - name: $VolumeName
      storageType: AzureFile
      storageName: $StorageName
"@
    
    # Adicionar volumes antes de scale ou no final do template
    if ($yamlContent -match "(\s+scale:.*?)(\s+volumes:|\s*$)") {
        # Se já tem scale, adicionar volumes depois
        $yamlContent = $yamlContent -replace "(\s+scale:.*?)(\s*$)", "`$1`n$volumesYaml"
    } elseif ($yamlContent -match "(\s+template:.*?)(\s+scale:|\s*$)") {
        # Adicionar antes de scale
        $yamlContent = $yamlContent -replace "(\s+template:.*?)(\s+scale:)", "`$1`n$volumesYaml`$2"
    } else {
        # Adicionar no final do template
        $yamlContent = $yamlContent -replace "(\s+template:.*?)(\s*$)", "`$1`n$volumesYaml"
    }
    Write-Host "[OK] volumes adicionado ao template" -ForegroundColor Green
} else {
    # Verificar se o volume correto já existe
    if ($yamlContent -match "name:\s*$VolumeName" -and $yamlContent -match "storageName:\s*$StorageName") {
        Write-Host "[OK] Volume '$VolumeName' já existe no template" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] Volumes existe mas volume '$VolumeName' não encontrado. Adicione manualmente." -ForegroundColor Yellow
    }
}

# Salvar YAML editado
$yamlContent | Out-File -FilePath $yamlFile -Encoding utf8 -NoNewline
Write-Host "[OK] YAML editado salvo: $yamlFile" -ForegroundColor Green
Write-Host ""

# 6. Aplicar update com revision-suffix
Write-Host "[INFO] Aplicando update com nova revision..." -ForegroundColor Yellow
$ErrorActionPreference = "Continue"

# Gerar revision suffix único se não fornecido
if ($RevisionSuffix -eq "docsfix") {
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $RevisionSuffix = "docsfix$timestamp"
}

try {
    az containerapp update `
        --name $ContainerApp `
        --resource-group $ResourceGroup `
        --yaml $yamlFile `
        --revision-suffix $RevisionSuffix 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Update aplicado com sucesso!" -ForegroundColor Green
        Write-Host "[OK] Nova revision: $ContainerApp--$RevisionSuffix" -ForegroundColor Green
    } else {
        Write-Host "[ERRO] Falha ao aplicar update!" -ForegroundColor Red
        Write-Host "[INFO] YAML mantido em: $yamlFile para inspeção" -ForegroundColor Cyan
        Write-Host "[INFO] Backup original em: $yamlFileBackup" -ForegroundColor Cyan
        exit 1
    }
} catch {
    Write-Host "[ERRO] Falha ao aplicar update: $_" -ForegroundColor Red
    Write-Host "[INFO] YAML mantido em: $yamlFile para inspeção" -ForegroundColor Cyan
    exit 1
}

$ErrorActionPreference = "Stop"
Write-Host ""

# 7. Validar resultado
Write-Host "[INFO] Validando volume mount..." -ForegroundColor Yellow
Start-Sleep -Seconds 5  # Aguardar propagação

$volumeMounts = az containerapp show `
    --name $ContainerApp `
    --resource-group $ResourceGroup `
    --query "properties.template.containers[?name=='$containerName'].volumeMounts" -o json | ConvertFrom-Json

if ($volumeMounts -and $volumeMounts.Count -gt 0) {
    $mount = $volumeMounts | Where-Object { $_.volumeName -eq $VolumeName -and $_.mountPath -eq $MountPath }
    if ($mount) {
        Write-Host "[OK] Volume mount configurado corretamente!" -ForegroundColor Green
        Write-Host "  - Volume Name: $($mount.volumeName)" -ForegroundColor Gray
        Write-Host "  - Mount Path: $($mount.mountPath)" -ForegroundColor Gray
    } else {
        Write-Host "[AVISO] Volume mount existe mas não está como esperado" -ForegroundColor Yellow
        Write-Host "[INFO] Volume mounts encontrados:" -ForegroundColor Cyan
        $volumeMounts | ConvertTo-Json | Write-Host
    }
} else {
    Write-Host "[ERRO] Volume mount ainda não está configurado!" -ForegroundColor Red
    Write-Host "[INFO] YAML usado mantido em: $yamlFile para inspeção" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "=== Concluído! ===" -ForegroundColor Green
Write-Host "[INFO] YAML usado mantido em: $yamlFile" -ForegroundColor Cyan
Write-Host "[INFO] Backup original em: $yamlFileBackup" -ForegroundColor Cyan
Write-Host ""
Write-Host "[INFO] Próximos passos:" -ForegroundColor Yellow
Write-Host "  1. Verificar se o diretório está acessível:" -ForegroundColor Cyan
Write-Host "     az containerapp exec -g $ResourceGroup -n $ContainerApp --command 'ls -la $MountPath'" -ForegroundColor Gray
Write-Host "  2. Se necessário, executar ingestão de documentos" -ForegroundColor Cyan
