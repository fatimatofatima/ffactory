FROM python:3.11-slim
RUN pip install --no-cache-dir python-telegram-bot==20.6 psycopg2-binary==2.9.9
ENV PYTHONUNBUFFERED=1 TZ=${TZ:-Asia/Kuwait}
WORKDIR /app
COPY bot.py /app/bot.py
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh


COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
