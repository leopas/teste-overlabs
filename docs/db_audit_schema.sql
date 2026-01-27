-- Schema para audit logging completo (chat log, criptografia, classificação de abuso)
-- Compatível com MySQL (incluindo Azure Database for MySQL)

-- 1. audit_session: Sessões de chat
CREATE TABLE IF NOT EXISTS audit_session (
  session_id        VARCHAR(64) PRIMARY KEY,
  user_id           VARCHAR(64) NULL,
  created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  client_fingerprint VARCHAR(128) NULL,
  KEY idx_user_last_seen (user_id, last_seen_at)
);

-- 2. audit_message: Mensagens user/assistant (chat log completo)
CREATE TABLE IF NOT EXISTS audit_message (
  id                BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  session_id        VARCHAR(64) NOT NULL,
  trace_id          VARCHAR(64) NOT NULL,
  role              ENUM('user','assistant','system') NOT NULL,
  text_hash         CHAR(64) NOT NULL,
  text_redacted     MEDIUMTEXT NULL,
  text_raw_enc      LONGTEXT NULL,              -- JSON envelope base64
  text_raw_enc_alg  VARCHAR(32) NULL,            -- ex: "AES-256-GCM"
  text_raw_enc_kid  VARCHAR(64) NULL,           -- key id (para rotação futura)
  created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_session_created (session_id, created_at),
  KEY idx_trace_id (trace_id),
  CONSTRAINT fk_message_session FOREIGN KEY (session_id) REFERENCES audit_session(session_id)
);

-- 3. audit_ask: Resumo técnico de cada chamada /ask
CREATE TABLE IF NOT EXISTS audit_ask (
  trace_id          VARCHAR(64) PRIMARY KEY,
  request_id        VARCHAR(64) NOT NULL,
  session_id        VARCHAR(64) NOT NULL,
  user_id           VARCHAR(64) NULL,
  question_hash     CHAR(64) NOT NULL,
  answer_hash       CHAR(64) NOT NULL,
  answer_source     ENUM('CACHE','LLM','REFUSAL') NOT NULL,
  confidence        FLOAT NULL,
  refusal_reason    VARCHAR(64) NULL,
  cache_key         CHAR(64) NULL,
  cache_hit         BOOLEAN NOT NULL DEFAULT FALSE,
  llm_model         VARCHAR(128) NULL,
  latency_ms        INT NULL,
  abuse_risk_score  FLOAT NULL,
  abuse_flags_json  TEXT NULL,                 -- JSON array de strings
  created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_session_created (session_id, created_at),
  KEY idx_user_created (user_id, created_at),
  CONSTRAINT fk_ask_session FOREIGN KEY (session_id) REFERENCES audit_session(session_id)
);

-- 4. audit_retrieval_chunk: Chunks retornados na consulta (topK)
CREATE TABLE IF NOT EXISTS audit_retrieval_chunk (
  id                BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  trace_id           VARCHAR(64) NOT NULL,
  `rank`             INT NOT NULL,
  doc_id             VARCHAR(128) NULL,
  document           VARCHAR(255) NULL,
  path               VARCHAR(512) NULL,
  chunk_id           VARCHAR(128) NULL,
  chunk_index        INT NULL,
  score_similarity   FLOAT NULL,
  score_trust         FLOAT NULL,
  score_freshness    FLOAT NULL,
  score_final        FLOAT NULL,
  text_hash          CHAR(64) NOT NULL,
  excerpt_redacted   TEXT NULL,
  created_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_trace_rank (trace_id, `rank`),
  CONSTRAINT fk_chunk_ask FOREIGN KEY (trace_id) REFERENCES audit_ask(trace_id)
);

-- 5. audit_vector_fingerprint: Fingerprint do vetor de embedding (opcional)
CREATE TABLE IF NOT EXISTS audit_vector_fingerprint (
  trace_id          VARCHAR(64) PRIMARY KEY,
  embedding_model    VARCHAR(128) NOT NULL,
  vector_dim         INT NOT NULL,
  vector_hash        CHAR(64) NOT NULL,        -- SHA256 do vetor serializado
  created_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_vector_ask FOREIGN KEY (trace_id) REFERENCES audit_ask(trace_id)
);
