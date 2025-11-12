#!/bin/bash
echo "📦 تثبيت Volatility 3..."

# Clone Volatility 3
git clone https://github.com/volatilityfoundation/volatility3.git
cd volatility3

# Install requirements
pip install -r requirements.txt

# Create symbolic link
ln -sf $(pwd)/vol.py /usr/local/bin/vol.py

echo "✅ تم تثبيت Volatility 3 بنجاح"
echo "🔧 الاختبار: vol.py -h"
