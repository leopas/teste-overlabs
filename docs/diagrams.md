# Galeria de Diagramas

Diagramas Mermaid usados na documentação. Cada um está ligado ao doc onde o fluxo ou a decisão é explicada.

---

## A) Contexto e containers (C4-like)

**Onde é explicado:** [Arquitetura](architecture.md#contexto-e-containers).

```mermaid
flowchart TB
    Client([Cliente])
    API[FastAPI API]
    Redis[(Redis)]
    Qdrant[(Qdrant)]
    LLM[LLM Provider\nOpenAI ou stub]
    MySQL[(MySQL\naudit opcional)]

    Client -->|POST /ask| API
    API --> Redis
    API --> Qdrant
    API --> LLM
    API -.->|TRACE_SINK=mysql| MySQL
```

---

## B) Deployment (Docker Compose)

**Onde é explicado:** [Arquitetura](architecture.md#deployment-docker-compose), [Runbook](runbook.md).

```mermaid
flowchart LR
    subgraph host["Host"]
        DOCS["/docs from DOCS_HOST_PATH"]
        DOCS_APP["./docs to /app/docs"]
        CFG["./config to /app/config"]
    end

    subgraph compose["Docker Compose"]
        API["api :8000"]
        QD["qdrant :6335 to 6333"]
        RD["redis :6379"]
    end

    API --> DOCS
    API --> DOCS_APP
    API --> CFG
    API --> QD
    API --> RD
    QD --> VOL[("qdrant_storage")]
```

---

## C) Sequência do /ask (detalhado)

**Onde é explicado:** [Arquitetura](architecture.md#fluxo-do-ask), [Observabilidade](observability.md).

```mermaid
sequenceDiagram
    participant C as Cliente
    participant A as API
    participant FW as Prompt Firewall
    participant R as Redis
    participant E as Embedder
    participant Q as Qdrant
    participant LLM as LLM
    participant Audit as Audit Sink

    C->>A: POST /ask {question}
    A->>A: normalize + guardrails + firewall
    alt firewall block
        A->>Audit: session, message, ask (REFUSAL)
        A-->>C: 200 REFUSAL, X-Answer-Source=REFUSAL
    end
    alt injection/sensitive
        A->>Audit: session, message, ask (REFUSAL)
        A-->>C: 200 REFUSAL
    end
    A->>R: get(cache_key)
    alt cache hit
        A->>Audit: message, ask (CACHE), chunks
        A-->>C: 200 + X-Answer-Source=CACHE
    end
    A->>E: embed(query)
    A->>Q: search top_k=8
    A->>A: rerank, select_evidence, conflict
    alt no evidence / conflict / quality fail
        A->>Audit: ask (REFUSAL)
        A-->>C: 200 REFUSAL
    end
    A->>LLM: generate(question, evidence)
    alt LLM refusal / error
        A->>Audit: ask (REFUSAL)
        A-->>C: 200 REFUSAL
    end
    A->>A: post-validate, confidence
    A->>R: set(cache_key, response)
    A->>Audit: message, ask (LLM), chunks
    A-->>C: 200 + X-Answer-Source=LLM, X-Trace-ID, X-Request-ID, X-Chat-Session-ID
```

---

## D) Pipeline de ingestão

**Onde é explicado:** [Arquitetura](architecture.md#pipeline-de-ingestão), [Runbook](runbook.md).

```mermaid
flowchart LR
    subgraph scan["scan_docs"]
        D1[DOCS_ROOT]
        L[Layout L1..L4]
        R[layout_report.md]
        D1 --> L --> R
    end

    subgraph ingest["ingest"]
        R --> chunk[Chunking 650+120]
        chunk --> skip{CPF/funcionários?}
        skip -->|sim| ignore[ignorar]
        skip -->|não| emb[Embeddings]
        emb --> upsert[Upsert Qdrant]
    end
```

---

## E) ER do schema de audit

**Onde é explicado:** [Audit logging](audit_logging.md#schema-mysql).

```mermaid
erDiagram
    audit_session ||--o{ audit_message : "session_id"
    audit_session ||--o{ audit_ask : "session_id"
    audit_ask ||--o{ audit_retrieval_chunk : "trace_id"
    audit_ask ||--o| audit_vector_fingerprint : "trace_id"

    audit_session {
        varchar session_id PK
        varchar user_id
        datetime last_seen_at
    }
    audit_message {
        bigint id PK
        varchar session_id FK
        varchar trace_id
        enum role
        char text_hash
        mediumtext text_redacted
        longtext text_raw_enc
    }
    audit_ask {
        varchar trace_id PK
        varchar request_id
        varchar session_id FK
        varchar question_hash
        varchar answer_hash
        enum answer_source
        varchar refusal_reason
        text firewall_rule_ids
        boolean cache_hit
    }
    audit_retrieval_chunk {
        bigint id PK
        varchar trace_id FK
        int rank
        varchar path
        float score_final
        char text_hash
    }
    audit_vector_fingerprint {
        varchar trace_id PK,FK
        varchar vector_hash
    }
```

---

## F) Observabilidade

**Onde é explicado:** [Observabilidade](observability.md).

```mermaid
flowchart LR
    API[FastAPI] --> Structlog[JSON Structlog]
    API --> Prom[Prometheus /metrics]
    API --> OTel[OpenTelemetry]
    OTel -.->|opcional| Collector[OTel Collector]
    Structlog --> LogAgg[Agregador de logs]
    Prom --> Scrape[Prometheus Scrape]
```

---

## G) Gates de segurança (request)

**Onde é explicado:** [Segurança](security.md#gates-do-request).

```mermaid
flowchart TD
    R[Request POST /ask] --> RL{Rate limit}
    RL -->|excedido| REF1[REFUSAL]
    RL -->|ok| FW{Prompt Firewall\nhabilitado?}
    FW -->|match| REF2[REFUSAL]
    FW -->|no match / off| G[Guardrails]
    G -->|injection| REF3[REFUSAL]
    G -->|sensitive/PII| REF4[REFUSAL]
    G -->|ok| Pipe[Pipeline RAG\ncache → retrieval → LLM]
```
