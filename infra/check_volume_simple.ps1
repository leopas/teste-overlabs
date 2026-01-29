# Script simples para verificar volume mount

$rg = "rg-overlabs-prod"
$app = "app-overlabs-prod-248"

Write-Host "=== VERIFICAÇÃO DE VOLUME MOUNT ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "1. Volumes definidos:" -ForegroundColor Yellow
az containerapp show --name $app --resource-group $rg --query "properties.template.volumes" -o json
Write-Host ""

Write-Host "2. Volume mounts no template:" -ForegroundColor Yellow
az containerapp show --name $app --resource-group $rg --query "properties.template.containers[0].volumeMounts" -o json
Write-Host ""

Write-Host "3. Latest revision:" -ForegroundColor Yellow
$rev = az containerapp show --name $app --resource-group $rg --query "properties.latestRevisionName" -o tsv
Write-Host $rev
Write-Host ""

Write-Host "4. Volume mounts na revision $rev :" -ForegroundColor Yellow
az containerapp revision show --name $rev --app $app --resource-group $rg --query "properties.template.containers[0].volumeMounts" -o json
Write-Host ""

Write-Host "5. Volumes na revision $rev :" -ForegroundColor Yellow
az containerapp revision show --name $rev --app $app --resource-group $rg --query "properties.template.volumes" -o json
Write-Host ""

Write-Host "6. Status da revision:" -ForegroundColor Yellow
az containerapp revision show --name $rev --app $app --resource-group $rg --query "{provisioningState:properties.provisioningState,active:properties.active,trafficWeight:properties.trafficWeight}" -o json
Write-Host ""

Write-Host "7. Verificação no container (mount):" -ForegroundColor Yellow
az containerapp exec --name $app --resource-group $rg --command "mount | grep -i doc || echo 'NO_MOUNT'" 2>&1
Write-Host ""

Write-Host "8. Conteúdo de /app:" -ForegroundColor Yellow
az containerapp exec --name $app --resource-group $rg --command "ls -la /app/ 2>&1 | head -10" 2>&1
Write-Host ""
