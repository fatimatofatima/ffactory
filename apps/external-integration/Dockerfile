FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl libmagic1 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir fastapi uvicorn requests python-magic numpy
COPY . .
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh


COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
