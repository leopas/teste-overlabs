FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY backend/requirements-extra.txt /app/requirements-extra.txt
RUN pip install --no-cache-dir -r /app/requirements-extra.txt

COPY backend/app /app/app
COPY backend/scripts /app/scripts
COPY docs /app/docs
COPY config /app/config
# Criar diretório certs (será populado se necessário)
RUN mkdir -p /app/certs
# Copiar certs (pode estar vazio - não falha)
COPY certs*.* /app/certs/ 2>/dev/null || echo "No certs to copy"

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

