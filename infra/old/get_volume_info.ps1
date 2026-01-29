# Script para obter informações do volume e salvar em arquivo

$rg = "rg-overlabs-prod"
$app = "app-overlabs-prod-300"
$outputFile = "volume_info_$(Get-Date -Format 'yyyyMMddHHmmss').json"

$info = @{
    timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    resourceGroup = $rg
    containerApp = $app
    volumes = $null
    volumeMounts = $null
    latestRevision = $null
    revisionVolumes = $null
    revisionMounts = $null
    revisionStatus = $null
    containerMount = $null
    appDirContent = $null
}

try {
    Write-Host "[INFO] Obtendo informações..." -ForegroundColor Yellow
    
    # Volumes
    $volumesJson = az containerapp show --name $app --resource-group $rg --query "properties.template.volumes" -o json 2>$null
    $info.volumes = $volumesJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    
    # Volume mounts
    $mountsJson = az containerapp show --name $app --resource-group $rg --query "properties.template.containers[0].volumeMounts" -o json 2>$null
    $info.volumeMounts = $mountsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    
    # Latest revision
    $info.latestRevision = az containerapp show --name $app --resource-group $rg --query "properties.latestRevisionName" -o tsv 2>$null
    
    if ($info.latestRevision) {
        # Revision volumes
        $revVolumesJson = az containerapp revision show --name $info.latestRevision --app $app --resource-group $rg --query "properties.template.volumes" -o json 2>$null
        $info.revisionVolumes = $revVolumesJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        
        # Revision mounts
        $revMountsJson = az containerapp revision show --name $info.latestRevision --app $app --resource-group $rg --query "properties.template.containers[0].volumeMounts" -o json 2>$null
        $info.revisionMounts = $revMountsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        
        # Revision status
        $revStatusJson = az containerapp revision show --name $info.latestRevision --app $app --resource-group $rg --query "{provisioningState:properties.provisioningState,active:properties.active,trafficWeight:properties.trafficWeight}" -o json 2>$null
        $info.revisionStatus = $revStatusJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    }
    
    # Container mount check
    $mountCheck = az containerapp exec --name $app --resource-group $rg --command "mount | grep -i doc || echo 'NO_MOUNT'" 2>&1
    $info.containerMount = $mountCheck
    
    # App dir content
    $appDir = az containerapp exec --name $app --resource-group $rg --command "ls -la /app/ 2>&1 | head -10" 2>&1
    $info.appDirContent = $appDir
    
    # Salvar em JSON
    $info | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputFile -Encoding utf8
    
    Write-Host "[OK] Informações salvas em: $outputFile" -ForegroundColor Green
    
    # Mostrar resumo
    Write-Host ""
    Write-Host "=== RESUMO ===" -ForegroundColor Cyan
    Write-Host "Latest Revision: $($info.latestRevision)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Volumes definidos:" -ForegroundColor Yellow
    if ($info.volumes) {
        $info.volumes | ConvertTo-Json -Depth 5
    } else {
        Write-Host "  null" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Volume mounts no template:" -ForegroundColor Yellow
    if ($info.volumeMounts) {
        $info.volumeMounts | ConvertTo-Json -Depth 5
    } else {
        Write-Host "  null" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Volume mounts na revision:" -ForegroundColor Yellow
    if ($info.revisionMounts) {
        $info.revisionMounts | ConvertTo-Json -Depth 5
    } else {
        Write-Host "  null" -ForegroundColor Red
    }
    
} catch {
    Write-Host "[ERRO] Falha ao obter informações: $_" -ForegroundColor Red
}
