#!/usr/bin/env python3
import yaml
import sys

# قراءة الملف
with open('docker-compose.ultimate.yml', 'r') as f:
    content = f.read()

# إصلاح المشاكل الشائعة في YAML
fixed_content = content.replace('environment', 'environment:')
fixed_content = fixed_content.replace('ports', 'ports:')
fixed_content = fixed_content.replace('volumes', 'volumes:')

# كتابة الملف المصحح
with open('docker-compose.ultimate.yml', 'w') as f:
    f.write(fixed_content)

print("✅ تم إصلاح ملف docker-compose")
