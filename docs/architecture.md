## Arquitetura (R1)

### Componentes
- **API**: FastAPI (`api`, porta 8000)
- **Vector DB**: Qdrant (`qdrant`, porta 6333)
- **Cache/Rate limit**: Redis (`redis`, porta 6379)
- **Docs de entrada**: volume do host montado em `/docs` dentro do container
- **Relatórios**: `./docs` do host montado em `/app/docs` (para `layout_report.md`)
- **Embeddings locais**: `fastembed` (ONNX) com `sentence-transformers/all-MiniLM-L6-v2`

### Fluxo do `/ask` (RAG com recusa)
1. Valida input (`question`)
2. Guardrails (prompt injection + sensível/PII)
3. Normaliza pergunta
4. Cache Redis (sha256 da pergunta normalizada)
5. Embedding + busca no Qdrant (top_k=8)
6. Re-rank com confiança/recência
7. Seleção de evidências (limite de tokens)
8. Detecção de conflito (números/prazos/datas)
9. LLM (OpenAI opcional; stub sem chave)
10. Regras de qualidade + confidence final
11. Resposta sempre 200 (inclusive recusa)

### Observabilidade
- Logs JSON estruturados: `request_id`, `latency_ms`, `cache_hit`, `top_docs`, `refusal_reason`
- Métricas Prometheus em `/metrics`
- OpenTelemetry opcional via env (sem quebrar se não houver collector)

