# Script para configurar Azure Key Vault e adicionar secrets
# Uso: .\azure\setup-keyvault.ps1 <resource-group> <keyvault-name>

param(
    [string]$ResourceGroup = "rag-overlabs-rg",
    [string]$KvName = "rag-overlabs-kv"
)

$ErrorActionPreference = "Stop"

Write-Host "🔐 Configurando Azure Key Vault: $KvName" -ForegroundColor Green

# Criar Key Vault (se não existir)
$kvExists = az keyvault show --name $KvName --resource-group $ResourceGroup 2>$null
if (-not $kvExists) {
    Write-Host "📦 Criando Key Vault..." -ForegroundColor Yellow
    az keyvault create `
        --name $KvName `
        --resource-group $ResourceGroup `
        --location brazilsouth `
        --sku standard | Out-Null
    Write-Host "✅ Key Vault criado!" -ForegroundColor Green
} else {
    Write-Host "✅ Key Vault já existe" -ForegroundColor Green
}

Write-Host ""
Write-Host "📝 Próximos passos:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # OpenAI API Key" -ForegroundColor Yellow
Write-Host "  az keyvault secret set --vault-name $KvName --name OpenAIApiKey --value '<sua-chave>'"
Write-Host ""
Write-Host "  # Audit Encryption Key (32 bytes base64)" -ForegroundColor Yellow
Write-Host "  python -c `"import os,base64; print(base64.b64encode(os.urandom(32)).decode())`""
Write-Host "  az keyvault secret set --vault-name $KvName --name AuditEncKey --value '<chave-gerada>'"
Write-Host ""
Write-Host "  # MySQL Password (se necessário)" -ForegroundColor Yellow
Write-Host "  az keyvault secret set --vault-name $KvName --name MysqlPassword --value '<senha>'"
Write-Host ""
Write-Host "🔗 Para usar no Container App:" -ForegroundColor Cyan
Write-Host "  az containerapp update --name rag-overlabs-app --resource-group $ResourceGroup \"
Write-Host "    --set-env-vars \"
Write-Host "      'OPENAI_API_KEY=@Microsoft.KeyVault(SecretUri=https://$KvName.vault.azure.net/secrets/OpenAIApiKey/)' \"
Write-Host "      'AUDIT_ENC_KEY_B64=@Microsoft.KeyVault(SecretUri=https://$KvName.vault.azure.net/secrets/AuditEncKey/)'"
Write-Host ""
