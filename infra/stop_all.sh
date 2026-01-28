#!/bin/bash
# Script para parar todos os containers do projeto
# Uso: ./infra/stop_all.sh

set -e

echo "=== Parar Containers do Projeto ==="
echo ""

# Verificar se Docker está rodando
if ! docker info >/dev/null 2>&1; then
    echo "[ERRO] Docker não está rodando. Inicie o Docker." >&2
    exit 1
fi

echo "[INFO] Parando containers do docker-compose.yml..."
if docker compose down 2>/dev/null; then
    echo "[OK] Containers do docker-compose.yml parados"
else
    echo "[AVISO] Nenhum container do docker-compose.yml rodando"
fi

echo ""
echo "[INFO] Verificando outros compose files..."

# Parar docker-compose.test.yml se existir
if [ -f "docker-compose.test.yml" ]; then
    if docker compose -f docker-compose.test.yml down 2>/dev/null; then
        echo "[OK] Containers do docker-compose.test.yml parados"
    fi
fi

# Parar docker-compose.deploy.yml se existir
if [ -f "docker-compose.deploy.yml" ]; then
    if docker compose -f docker-compose.deploy.yml down 2>/dev/null; then
        echo "[OK] Containers do docker-compose.deploy.yml parados"
    fi
fi

# Parar docker-compose.azure.yml se existir
if [ -f "docker-compose.azure.yml" ]; then
    if docker compose -f docker-compose.azure.yml down 2>/dev/null; then
        echo "[OK] Containers do docker-compose.azure.yml parados"
    fi
fi

echo ""
echo "[INFO] Verificando containers órfãos do projeto..."

# Listar containers rodando que podem ser do projeto
containers=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "teste-overlabs|choperia|qdrant|redis" || true)
if [ -n "$containers" ]; then
    echo "[INFO] Encontrados containers adicionais:"
    echo "$containers" | while read -r container; do
        echo "  - $container"
        if docker stop "$container" 2>/dev/null; then
            echo "    [OK] Parado"
        fi
    done
else
    echo "[OK] Nenhum container órfão encontrado"
fi

echo ""
echo "=== Todos os containers parados! ==="
echo ""

# Mostrar status final
echo "[INFO] Containers ainda rodando:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
