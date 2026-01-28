# Exemplos de Teste da API /ask

## PowerShell (Windows)

### Usando o script automatizado:
```powershell
# Testar no staging
.\infra\test_ask_api.ps1 -Question "Qual é a política de reembolso?" -Slot staging

# Testar na produção
.\infra\test_ask_api.ps1 -Question "Qual é a política de reembolso?" -Slot production
```

### Usando curl direto (PowerShell):
```powershell
# Carregar informações do deploy
$state = Get-Content .azure/deploy_state.json | ConvertFrom-Json

# Testar no staging
$url = "https://$($state.appServiceName)-staging.azurewebsites.net/ask"
$body = @{ question = "Qual é a política de reembolso?" } | ConvertTo-Json -Compress

Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
```

### Usando curl.exe (se disponível):
```powershell
$state = Get-Content .azure/deploy_state.json | ConvertFrom-Json
$url = "https://$($state.appServiceName)-staging.azurewebsites.net/ask"

curl.exe -X POST `
  -H "Content-Type: application/json" `
  -H "Accept: application/json" `
  -d '{\"question\":\"Qual é a política de reembolso?\"}' `
  $url
```

## Bash/Linux

### Usando o script automatizado:
```bash
# Testar no staging
./infra/test_ask_api.sh "Qual é a política de reembolso?" staging

# Testar na produção
./infra/test_ask_api.sh "Qual é a política de reembolso?" production
```

### Usando curl direto:
```bash
# Carregar informações do deploy
WEB_APP=$(jq -r '.appServiceName' .azure/deploy_state.json)

# Testar no staging
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"question":"Qual é a política de reembolso?"}' \
  "https://${WEB_APP}-staging.azurewebsites.net/ask" | jq '.'
```

## Exemplos de Perguntas

### Perguntas válidas:
- "Qual é a política de reembolso?"
- "Como solicitar reembolso de viagem?"
- "Qual o prazo para aprovação de reembolso?"
- "Quais documentos são necessários para reembolso?"

### Formato da Resposta:
```json
{
  "answer": "Resposta gerada pela IA...",
  "confidence": 0.85,
  "sources": [
    {
      "document": "politica_reembolso_v3.txt",
      "excerpt": "Trecho relevante do documento..."
    }
  ]
}
```

## Headers Opcionais

Você pode incluir headers opcionais para rastreabilidade:

```powershell
$headers = @{
    "Content-Type" = "application/json"
    "X-Request-ID" = "meu-request-id-123"
    "X-Chat-Session-ID" = "sessao-abc-123"
    "X-User-ID" = "usuario-xyz"
}

Invoke-RestMethod -Uri $url -Method Post -Body $body -Headers $headers
```

## Troubleshooting

### Erro 503 (Service Unavailable)
- Verifique se os containers estão rodando
- Verifique os logs: `az webapp log tail --name <app-name> --resource-group <rg> --slot staging`

### Erro 422 (Validation Error)
- Verifique se a pergunta tem entre 3 e 2000 caracteres
- Verifique se não há caracteres de controle na pergunta

### Erro 500 (Internal Server Error)
- Verifique os logs do App Service
- Verifique se Qdrant e Redis estão acessíveis
- Verifique se as variáveis de ambiente estão configuradas corretamente
