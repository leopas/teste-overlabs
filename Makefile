COMPOSE_TEST=docker compose -f docker-compose.test.yml
COMPOSE_PROJECT_NAME=ragtest

.PHONY: test test-unit test-prod test-live test-fuzz

test: test-unit test-prod

test-unit:
	@cd backend && pytest -q -m "not prodlike"

test-fuzz:
	@cd backend && pytest -q tests/property

test-prod:
	@echo ">> Starting prod-like deps (qdrant+redis)..."
	@set COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) && $(COMPOSE_TEST) up -d
	@echo ">> Running prod-like tests..."
	@cd backend && set QDRANT_URL=http://localhost:6336 && set REDIS_URL=redis://localhost:6380/0 && pytest -q -m "prodlike"
	@echo ">> Stopping prod-like deps..."
	@set COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) && $(COMPOSE_TEST) down -v

test-live:
	@cd backend && pytest -q -m "live_llm"

