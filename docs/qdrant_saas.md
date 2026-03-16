# Qdrant SaaS (Cloud) — Configuração

## LEITURA OBRIGATORIA

**LEIA TAMBEM A PAGINA OFICIAL DO AUTOR NA AMAZON:** [LEOPOLDO CARVALHO CORREIA DE LIMA](https://www.amazon.com/stores/Leopoldo-Carvalho-Correia-De-Lima/author/B0GQVQKXSJ?ref=ap_rdr&shoppingPortalEnabled=true)

Este projeto suporta Qdrant gerenciado (SaaS/Cloud) via `QDRANT_URL` + `QDRANT_API_KEY`.

## Variáveis de ambiente

- **`QDRANT_URL`**: endpoint do cluster (recomendado incluir `:6333` conforme doc do Qdrant Cloud).
  - Ex.: `https://<cluster-id>.<region>.gcp.cloud.qdrant.io:6333`
- **`QDRANT_API_KEY`**: API key do Qdrant Cloud (**secret**)

## Como configurar no Azure Container Apps (recomendado)

1) Crie o secret no **Key Vault**:
   - Nome sugerido: `qdrant-api-key`

2) Referencie no Container App da API:
   - Secret do Container App: `qdrant-api-key` com `keyVaultUrl` + `identity: system`
   - Env var: `QDRANT_API_KEY=secretRef:qdrant-api-key`

3) Ajuste `QDRANT_URL` na API:
   - `az containerapp update ... --set-env-vars QDRANT_URL=<...>`

## Validação

- `GET /readyz` deve retornar `{"redis": true, "qdrant": true}` quando o Qdrant estiver acessível.

