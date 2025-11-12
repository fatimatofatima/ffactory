FROM python:3.11-slim

# تثبيت dependencies النظام
RUN apt-get update && apt-get install -y \
    git \
    wget \
    curl \
    file \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# تثبيت Volatility 3
RUN git clone https://github.com/volatilityfoundation/volatility3.git \
    && cd volatility3 \
    && pip install -r requirements.txt \
    && ln -s /app/volatility3/vol.py /usr/local/bin/vol.py

# نسخ متطلبات Python
COPY requirements.txt .

# تثبيت متطلبات Python
RUN pip install --no-cache-dir -r requirements.txt

# نسخ التطبيق
COPY . .

EXPOSE 8015

CMD ["python", "memory_analyzer/advanced_memory_forensics.py"]
