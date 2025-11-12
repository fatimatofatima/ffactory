FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8089
ENV S3_ENDPOINT=ffactory_minio:9000 S3_SECURE=0
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8089"]
