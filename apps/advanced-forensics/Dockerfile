FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip ca-certificates libmagic1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Volatility3
RUN git clone --depth 1 https://github.com/volatilityfoundation/volatility3.git && \
    ln -s /app/volatility3/vol.py /usr/local/bin/vol.py

COPY main.py .
ENV VOLATILITY_SYMBOLPATH=file:///symbols
EXPOSE 8015
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh


COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
