# Fix: Qdrant via HTTPS no FQDN do ingress (ACA)

## Causa raiz
No Azure Container Apps, quando o ingress do Qdrant é **HTTP (L7)** com `targetPort: 6333`, **a porta 6333 não é exposta diretamente** para outros apps. O `targetPort` é a porta **dentro do container**; o tráfego entra via **80/443** no ingress.

Na prática:
- `http://<host>:6333` tende a falhar (timeout) quando o app só tem ingress HTTP.
- Usar host “curto” (`app-name`) também pode falhar por roteamento (Host header).

## Correção (recomendada)
Configurar o Qdrant com:
- ingress **internal**
- transport **http**
- `targetPort=6333`
- `allowInsecure=false` (HTTPS-only)

E configurar a API com:
- `QDRANT_URL=https://<fqdn-do-ingress-do-qdrant>` (sem `:6333`)

## Como aplicar (script)
Use:

```powershell
.\infra\bootstrap_qdrant_ingress_https.ps1 `
  -ResourceGroup "rg-overlabs-prod" `
  -QdrantAppName "app-overlabs-qdrant-prod-300" `
  -ApiAppName "app-overlabs-prod-300" `
  -SetApiEnv:$true
```

## Como verificar

```powershell
az containerapp ingress show -g rg-overlabs-prod -n app-overlabs-qdrant-prod-300 -o json
az containerapp show -g rg-overlabs-prod -n app-overlabs-prod-300 --query "properties.template.containers[0].env[?name=='QDRANT_URL']" -o json
```

E testar:
- `https://<api-fqdn>/readyz` deve voltar `{"redis":true,"qdrant":true}`.

## Reversão
Se precisar voltar para permitir HTTP (não recomendado):

```powershell
az containerapp ingress update -g rg-overlabs-prod -n app-overlabs-qdrant-prod-300 --allow-insecure true
```

E então apontar a API para `http://<fqdn>` (sem `:6333`).

