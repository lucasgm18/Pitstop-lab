#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# PITSTOP CORE - INCIDENT BENCHMARK TEST RUNNER WRAPPER
# Executa a suite de testes Python 3.11 conectando-se ao container
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ">>> Verificando se o container pitstop_postgres está saudável..."
if ! docker inspect -f '{{.State.Health.Status}}' pitstop_postgres 2>/dev/null | grep -q "healthy"; then
    echo "Container não encontrado ou ainda inicializando. Iniciando docker-compose..."
    docker compose -f docker/docker-compose.yml up -d
    sleep 3
fi

# Carrega variáveis de ambiente locais do docker/.env se existirem
if [ -f docker/.env ]; then
    set -a
    source docker/.env
    set +a
fi

echo ">>> Executando suite de benchmarks via Python 3.11 isolado..."
docker run --rm \
    --network docker_default \
    -v "$SCRIPT_DIR":/app \
    -w /app \
    -e PGHOST="${PGHOST:-pitstop_postgres}" \
    -e PGPORT="5432" \
    -e PGDATABASE="${POSTGRES_DB:-${PGDATABASE:-pitstop_db}}" \
    -e PGUSER="${POSTGRES_USER:-${PGUSER:-pitstop_admin}}" \
    -e PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}" \
    -e PYTHONUNBUFFERED=1 \
    python:3.11-slim \
    bash -c "pip install --quiet --no-cache-dir -r tests/requirements.txt && python tests/run_incident_benchmarks.py"
