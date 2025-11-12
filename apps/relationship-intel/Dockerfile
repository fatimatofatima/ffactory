FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8088/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8088"]
