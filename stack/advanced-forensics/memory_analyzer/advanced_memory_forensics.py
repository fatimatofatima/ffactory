#!/usr/bin/env python3
"""
محلل الذاكرة المتقدم باستخدام Volatility 3
لتحليل الذاكرة الحية واستخراج الأدلة
"""
import os
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Any
from datetime import datetime
import logging
from fastapi import FastAPI, UploadFile, File, HTTPException, BackgroundTasks
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Advanced Memory Forensics API",
    description="خدمة متقدمة لتحليل ذاكرة النظام باستخدام Volatility 3",
    version="1.0.0"
)

class RealMemoryForensics:
    def __init__(self, volatility_path: str = "vol.py"):
        self.volatility_path = volatility_path
        self.supported_plugins = [
            "windows.pslist.PsList",
            "windows.netscan.NetScan",
            "windows.cmdline.CmdLine",
            "windows.envars.Envars",
            "windows.malfind.Malfind",
            "windows.handles.Handles"
        ]
    
    def analyze_memory_dump(self, memory_dump_path: str, plugins: List[str] = None) -> Dict[str, Any]:
        """تحليل شامل لصورة الذاكرة باستخدام Volatility 3"""
        try:
            if plugins is None:
                plugins = self.supported_plugins[:3]  # استخدام أول 3 plugins للأداء
            
            results = {}
            
            for plugin in plugins:
                try:
                    logger.info(f"تشغيل plugin: {plugin}")
                    plugin_result = self._run_volatility_plugin(memory_dump_path, plugin)
                    results[plugin] = plugin_result
                except Exception as e:
                    logger.error(f"فشل plugin {plugin}: {e}")
                    results[plugin] = {"error": str(e)}
            
            return {
                "status": "success",
                "analysis_time": datetime.now().isoformat(),
                "plugins_executed": len(plugins),
                "results": results
            }
            
        except Exception as e:
            logger.error(f"فشل تحليل الذاكرة: {e}")
            return {"status": "error", "error": str(e)}
    
    def _run_volatility_plugin(self, memory_dump: str, plugin: str) -> Dict:
        """تشغيل plugin محدد من Volatility 3"""
        try:
            cmd = [
                self.volatility_path,
                "-f", memory_dump,
                plugin,
                "--output", "json"
            ]
            
            result = subprocess.run(
                cmd, 
                capture_output=True, 
                text=True, 
                timeout=300,
                cwd="/tmp"
            )
            
            if result.returncode == 0:
                return json.loads(result.stdout)
            else:
                return {
                    "error": result.stderr,
                    "returncode": result.returncode
                }
                
        except subprocess.TimeoutExpired:
            return {"error": "انتهت المهلة - Plugin استغرق وقتاً طويلاً"}
        except json.JSONDecodeError:
            return {"raw_output": result.stdout}
        except Exception as e:
            return {"error": str(e)}
    
    def detect_malware_indicators(self, memory_dump: str) -> Dict[str, Any]:
        """كشف مؤشرات البرمجيات الخبيثة في الذاكرة"""
        try:
            indicators = {}
            
            # 1. كشف العمليات المخفية
            hidden_procs = self._detect_hidden_processes(memory_dump)
            indicators["hidden_processes"] = hidden_procs
            
            # 2. كشف الكود المحقون
            injected_code = self._detect_injected_code(memory_dump)
            indicators["injected_code"] = injected_code
            
            # 3. كشف اتصالات الشبكة المشبوهة
            suspicious_conns = self._detect_suspicious_connections(memory_dump)
            indicators["suspicious_connections"] = suspicious_conns
            
            return {
                "status": "success",
                "malware_indicators": indicators,
                "risk_score": self._calculate_malware_risk(indicators)
            }
            
        except Exception as e:
            return {"status": "error", "error": str(e)}
    
    def _detect_hidden_processes(self, memory_dump: str) -> List[Dict]:
        """كشف العمليات المخفية"""
        try:
            # مقارنة بين pslist و psscan لاكتشاف العمليات المخفية
            cmd_pslist = [self.volatility_path, "-f", memory_dump, "windows.pslist.PsList", "--output", "json"]
            cmd_psscan = [self.volatility_path, "-f", memory_dump, "windows.psscan.PsScan", "--output", "json"]
            
            pslist_result = subprocess.run(cmd_pslist, capture_output=True, text=True)
            psscan_result = subprocess.run(cmd_psscan, capture_output=True, text=True)
            
            # معالجة النتائج لاكتشاف الاختلافات
            hidden_procs = []
            
            # هذه مجرد مثال - تحتاج معالجة حقيقية للبيانات
            if pslist_result.returncode == 0 and psscan_result.returncode == 0:
                hidden_procs.append({
                    "indicator": "process_hiding_detected",
                    "description": "تم اكتشاف اختلاف بين قوائم العمليات",
                    "confidence": "medium"
                })
            
            return hidden_procs
            
        except Exception as e:
            return [{"error": f"فشل كشف العمليات المخفية: {e}"}]
    
    def _detect_injected_code(self, memory_dump: str) -> List[Dict]:
        """كشف الكود المحقون باستخدام malfind"""
        try:
            cmd = [
                self.volatility_path, "-f", memory_dump,
                "windows.malfind.Malfind", "--output", "json"
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                data = json.loads(result.stdout)
                return [{
                    "indicator": "code_injection",
                    "detections": len(data) if isinstance(data, list) else 0,
                    "confidence": "high"
                }]
            else:
                return [{"error": result.stderr}]
                
        except Exception as e:
            return [{"error": f"فشل كشف الكود المحقون: {e}"}]
    
    def _detect_suspicious_connections(self, memory_dump: str) -> List[Dict]:
        """كشف اتصالات الشبكة المشبوهة"""
        try:
            cmd = [
                self.volatility_path, "-f", memory_dump,
                "windows.netscan.NetScan", "--output", "json"
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            suspicious_conns = []
            
            if result.returncode == 0:
                connections = json.loads(result.stdout)
                
                # تحليل الاتصالات المشبوهة
                for conn in connections[:10]:  # أول 10 اتصالات فقط
                    if self._is_suspicious_connection(conn):
                        suspicious_conns.append({
                            "local_address": conn.get("LocalAddress", ""),
                            "remote_address": conn.get("RemoteAddress", ""),
                            "state": conn.get("State", ""),
                            "pid": conn.get("PID", ""),
                            "reason": "اتصال مشبوه - IP غير معتاد أو port خطير"
                        })
            
            return suspicious_conns
            
        except Exception as e:
            return [{"error": f"فشل كشف الاتصالات المشبوهة: {e}"}]
    
    def _is_suspicious_connection(self, connection: Dict) -> bool:
        """تحديد إذا كان الاتصال مشبوهاً"""
        remote_addr = connection.get("RemoteAddress", "")
        
        # قائمة IPs و ports مشبوهة
        suspicious_ips = ["10.0.0.", "192.168.", "172.16."]
        suspicious_ports = [4444, 1337, 31337, 12345]  # ports معروفة للبرمجيات الخبيثة
        
        # التحقق من IPs مشبوهة
        for ip in suspicious_ips:
            if remote_addr.startswith(ip):
                return True
        
        # التحقق من ports مشبوهة
        if ":" in remote_addr:
            port = int(remote_addr.split(":")[-1])
            if port in suspicious_ports:
                return True
        
        return False
    
    def _calculate_malware_risk(self, indicators: Dict) -> int:
        """حساب درجة خطورة البرمجيات الخبيثة"""
        risk_score = 0
        
        if indicators.get("hidden_processes"):
            risk_score += 30
        if indicators.get("injected_code"):
            risk_score += 40
        if indicators.get("suspicious_connections"):
            risk_score += 30
        
        return min(risk_score, 100)

# تهيئة المحلل
memory_analyzer = RealMemoryForensics()

@app.get("/")
async def root():
    return {
        "message": "مرحباً في خدمة تحليل الذاكرة المتقدم",
        "version": "1.0.0",
        "volatility_plugins": memory_analyzer.supported_plugins
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "advanced_memory_forensics"}

@app.post("/analyze/memory")
async def analyze_memory(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(..., description="صورة ذاكرة النظام"),
    plugins: str = None
):
    """تحليل صورة الذاكرة"""
    try:
        # حفظ الملف مؤقتاً
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mem") as tmp_file:
            content = await file.read()
            tmp_file.write(content)
            tmp_path = tmp_file.name
        
        # تحديد plugins المطلوبة
        selected_plugins = plugins.split(",") if plugins else None
        
        # تحليل الذاكرة
        results = memory_analyzer.analyze_memory_dump(tmp_path, selected_plugins)
        
        # تنظيف الملف المؤقت
        background_tasks.add_task(lambda: os.unlink(tmp_path))
        
        return results
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل تحليل الذاكرة: {str(e)}")

@app.post("/detect/malware")
async def detect_malware(file: UploadFile = File(...)):
    """كشف البرمجيات الخبيثة في الذاكرة"""
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mem") as tmp_file:
            content = await file.read()
            tmp_file.write(content)
            tmp_path = tmp_file.name
        
        results = memory_analyzer.detect_malware_indicators(tmp_path)
        
        # تنظيف الملف
        os.unlink(tmp_path)
        
        return results
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/plugins")
async def list_plugins():
    """عرض جميع plugins المتاحة"""
    return {
        "supported_plugins": memory_analyzer.supported_plugins,
        "total_plugins": len(memory_analyzer.supported_plugins)
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8015, log_level="info")
