# Script para verificar detalhes completos da montagem do volume

param(
    [string]$ResourceGroup = "rg-overlabs-prod",
    [string]$ApiAppName = "app-overlabs-prod-300"
)

$ErrorActionPreference = "Continue"

Write-Host "=== Verificação Detalhada de Volume Mount ===" -ForegroundColor Cyan
Write-Host ""

$outputFile = "volume_check_$(Get-Date -Format 'yyyyMMddHHmmss').txt"
$output = @()

function Add-Output {
    param([string]$text, [string]$color = "White")
    Write-Host $text -ForegroundColor $color
    $script:output += $text
}

Add-Output "=== VERIFICAÇÃO DE VOLUME MOUNT ===" "Cyan"
Add-Output "Data/Hora: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Output "Resource Group: $ResourceGroup"
Add-Output "Container App: $ApiAppName"
Add-Output ""

# 1. Volumes definidos no Container App (template atual)
Add-Output "=== 1. VOLUMES DEFINIDOS NO CONTAINER APP ===" "Yellow"
$volumes = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json 2>&1
Add-Output $volumes
Add-Output ""

# 2. Volume mounts no Container App (template atual)
Add-Output "=== 2. VOLUME MOUNTS NO CONTAINER APP ===" "Yellow"
$volumeMounts = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json 2>&1
Add-Output $volumeMounts
Add-Output ""

# 3. Latest revision name
Add-Output "=== 3. REVISION ATIVA ===" "Yellow"
$latestRevision = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "properties.latestRevisionName" -o tsv 2>&1
Add-Output "Latest Revision: $latestRevision"
Add-Output ""

# 4. Volumes na revision específica
Add-Output "=== 4. VOLUMES NA REVISION $latestRevision ===" "Yellow"
$revisionVolumes = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "properties.template.volumes" -o json 2>&1
Add-Output $revisionVolumes
Add-Output ""

# 5. Volume mounts na revision específica
Add-Output "=== 5. VOLUME MOUNTS NA REVISION $latestRevision ===" "Yellow"
$revisionMounts = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "properties.template.containers[0].volumeMounts" -o json 2>&1
Add-Output $revisionMounts
Add-Output ""

# 6. Status da revision
Add-Output "=== 6. STATUS DA REVISION ===" "Yellow"
$revisionStatus = az containerapp revision show --name $latestRevision --app $ApiAppName --resource-group $ResourceGroup --query "{provisioningState:properties.provisioningState,active:properties.active,trafficWeight:properties.trafficWeight,replicas:properties.replicas}" -o json 2>&1
Add-Output $revisionStatus
Add-Output ""

# 7. Lista de todas as revisions
Add-Output "=== 7. TODAS AS REVISIONS ===" "Yellow"
$allRevisions = az containerapp revision list --name $ApiAppName --resource-group $ResourceGroup --query "[].{name:name,active:properties.active,trafficWeight:properties.trafficWeight,created:properties.createdTime,provisioningState:properties.provisioningState}" -o table 2>&1
Add-Output $allRevisions
Add-Output ""

# 8. Verificar mount no container (se estiver rodando)
Add-Output "=== 8. VERIFICAÇÃO NO CONTAINER (mount point) ===" "Yellow"
$mountCheck = az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command "mount | grep -i doc || echo 'NO_MOUNT_FOUND'" 2>&1
Add-Output $mountCheck
Add-Output ""

# 9. Listar diretório /app
Add-Output "=== 9. CONTEÚDO DE /app ===" "Yellow"
$appDir = az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command "ls -la /app/ 2>&1 | head -20" 2>&1
Add-Output $appDir
Add-Output ""

# 10. Verificar se /app/DOC-IA existe
Add-Output "=== 10. VERIFICAÇÃO DE /app/DOC-IA ===" "Yellow"
$docsCheck = az containerapp exec --name $ApiAppName --resource-group $ResourceGroup --command "test -d /app/DOC-IA && echo 'EXISTS' || echo 'NOT_FOUND'; ls -la /app/DOC-IA 2>&1" 2>&1
Add-Output $docsCheck
Add-Output ""

# 11. Verificar configuração completa do container
Add-Output "=== 11. CONFIGURAÇÃO COMPLETA DO CONTAINER ===" "Yellow"
$containerConfig = az containerapp show --name $ApiAppName --resource-group $ResourceGroup --query "{name:name,latestRevision:properties.latestRevisionName,containers:properties.template.containers[0],volumes:properties.template.volumes}" -o json 2>&1
Add-Output $containerConfig
Add-Output ""

# Salvar em arquivo
$output | Out-File -FilePath $outputFile -Encoding utf8

Write-Host ""
Write-Host "=== RESUMO ===" -ForegroundColor Cyan
Write-Host ""

# Processar resultados
$hasVolume = $volumes -notmatch "null|\[\]" -and $volumes -match "docs"
$hasMount = $volumeMounts -notmatch "null|\[\]" -and $volumeMounts -match "docs"
$hasRevisionMount = $revisionMounts -notmatch "null|\[\]" -and $revisionMounts -match "docs"
$hasAccess = $docsCheck -match "EXISTS"

Write-Host "Volumes definidos: $(if ($hasVolume) { '[OK]' } else { '[FALTA]' })" -ForegroundColor $(if ($hasVolume) { "Green" } else { "Red" })
Write-Host "Volume mounts no template: $(if ($hasMount) { '[OK]' } else { '[FALTA]' })" -ForegroundColor $(if ($hasMount) { "Green" } else { "Red" })
Write-Host "Volume mounts na revision: $(if ($hasRevisionMount) { '[OK]' } else { '[FALTA]' })" -ForegroundColor $(if ($hasRevisionMount) { "Green" } else { "Red" })
Write-Host "Diretório acessível: $(if ($hasAccess) { '[OK]' } else { '[FALTA]' })" -ForegroundColor $(if ($hasAccess) { "Green" } else { "Red" })

Write-Host ""
Write-Host "[INFO] Saída completa salva em: $outputFile" -ForegroundColor Cyan
Write-Host "[INFO] Abra o arquivo para ver todos os detalhes" -ForegroundColor Cyan
Write-Host ""

# Recomendações
if (-not $hasMount -or -not $hasRevisionMount) {
    Write-Host "[AÇÃO NECESSÁRIA] Volume mount não está configurado na revision ativa!" -ForegroundColor Red
    Write-Host "Execute: .\infra\add_volume_mount.ps1" -ForegroundColor Yellow
} elseif (-not $hasAccess) {
    Write-Host "[AÇÃO NECESSÁRIA] Volume mount configurado mas diretório não acessível!" -ForegroundColor Yellow
    Write-Host "Possíveis causas:" -ForegroundColor Yellow
    Write-Host "  1. Nova revision ainda não foi aplicada completamente" -ForegroundColor Gray
    Write-Host "  2. Container precisa ser reiniciado" -ForegroundColor Gray
    Write-Host "  3. Problema com permissões no Storage Account" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Tente:" -ForegroundColor Yellow
    Write-Host "  az containerapp revision restart --name $ApiAppName --resource-group $ResourceGroup --revision $latestRevision" -ForegroundColor Gray
}
