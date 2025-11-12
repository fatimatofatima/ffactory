FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git libsndfile1 curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 torchaudio==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
