-- Schema sugerido para persistência de rastreabilidade (pipeline traces)
-- Compatível com MySQL (incluindo Azure Database for MySQL)

CREATE TABLE IF NOT EXISTS pipeline_trace (
  trace_id        VARCHAR(64) PRIMARY KEY,
  request_id      VARCHAR(64) NOT NULL,
  user_id         VARCHAR(255) NULL,
  question_hash   CHAR(64) NOT NULL,
  started_at      VARCHAR(64) NOT NULL,
  finished_at     VARCHAR(64) NULL,
  duration_ms     INT NULL,
  outcome         VARCHAR(16) NULL,
  refusal_reason  VARCHAR(64) NULL,
  confidence      DOUBLE NULL,
  model           VARCHAR(128) NULL,
  cache_hit       TINYINT NULL,
  topk            INT NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_user_created (user_id, created_at),
  KEY idx_question_hash (question_hash),
  KEY idx_outcome (outcome)
);

CREATE TABLE IF NOT EXISTS pipeline_event (
  id            BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  trace_id      VARCHAR(64) NOT NULL,
  seq           INT NOT NULL,
  name          VARCHAR(128) NOT NULL,
  ts            VARCHAR(64) NOT NULL,
  duration_ms   INT NULL,
  attrs_json    JSON NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_trace_seq (trace_id, seq),
  CONSTRAINT fk_event_trace FOREIGN KEY (trace_id) REFERENCES pipeline_trace(trace_id)
);

