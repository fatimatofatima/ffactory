#!/usr/bin/env python3
"""
محلل أجهزة USB وسجلات النظام
لتحليل الأجهزة المتصلة وتواريخ الاتصال
"""
import json
import logging
from typing import Dict, List, Any
from datetime import datetime
from fastapi import FastAPI, HTTPException
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="USB Device Forensics API",
    description="خدمة تحليل أجهزة USB وسجلات النظام",
    version="1.0.0"
)

class USBForensicsAnalyzer:
    def __init__(self):
        self.usb_vendors = {
            "0781": "SanDisk",
            "0951": "Kingston",
            "0930": "Toshiba",
            "04E8": "Samsung",
            "13FE": "Kingston",
            "1000": "Generic"
        }
    
    def analyze_usb_devices(self, registry_data: Dict = None) -> Dict[str, Any]:
        """تحليل أجهزة USB من سجلات النظام"""
        try:
            # محاكاة بيانات USB من سجلات Windows
            usb_devices = self._simulate_usb_analysis()
            
            return {
                "status": "success",
                "analysis_time": datetime.now().isoformat(),
                "total_devices_found": len(usb_devices),
                "usb_devices": usb_devices,
                "suspicious_activity": self._detect_suspicious_usb_activity(usb_devices)
            }
            
        except Exception as e:
            return {"status": "error", "error": str(e)}
    
    def _simulate_usb_analysis(self) -> List[Dict]:
        """محاكاة تحليل أجهزة USB (ستستبدل ببيانات حقيقية)"""
        return [
            {
                "device_id": "VID_0781&PID_5590",
                "vendor": "SanDisk",
                "product": "Ultra Fit",
                "serial_number": "4C530001250123109999",
                "first_connected": "2024-01-15T10:30:00",
                "last_connected": "2024-01-15T14:45:00",
                "connection_count": 3,
                "suspicious": False
            },
            {
                "device_id": "VID_13FE&PID_5200",
                "vendor": "Kingston",
                "product": "DataTraveler",
                "serial_number": "001372ABC6D5EF901234",
                "first_connected": "2024-01-14T22:15:00",
                "last_connected": "2024-01-14T22:20:00",
                "connection_count": 1,
                "suspicious": True,
                "suspicion_reason": "اتصال ليلي قصير المدة"
            },
            {
                "device_id": "VID_0951&PID_1666",
                "vendor": "Kingston",
                "product": "DT HyperX",
                "serial_number": "60A44C412B9C987654321",
                "first_connected": "2024-01-10T09:00:00",
                "last_connected": "2024-01-15T16:30:00",
                "connection_count": 12,
                "suspicious": False
            }
        ]
    
    def _detect_suspicious_usb_activity(self, devices: List[Dict]) -> Dict[str, Any]:
        """كشف النشاط المشبوه لأجهزة USB"""
        suspicious_devices = []
        night_connections = 0
        short_connections = 0
        
        for device in devices:
            # التحقق من الاتصالات الليلية (بين 10 مساءً و 5 صباحاً)
            last_conn = datetime.fromisoformat(device["last_connected"].replace('Z', '+00:00'))
            if 22 <= last_conn.hour or last_conn.hour <= 5:
                night_connections += 1
                device["suspicious"] = True
                device["suspicion_reason"] = "اتصال ليلي"
                suspicious_devices.append(device)
            
            # التحقق من الاتصالات القصيرة (أقل من 5 دقائق)
            if device["connection_count"] == 1:
                short_connections += 1
                if not device.get("suspicious"):
                    device["suspicious"] = True
                    device["suspicion_reason"] = "اتصال وحيد قصير"
                    suspicious_devices.append(device)
        
        return {
            "suspicious_devices_count": len(suspicious_devices),
            "night_connections": night_connections,
            "short_connections": short_connections,
            "risk_level": "HIGH" if len(suspicious_devices) > 0 else "LOW",
            "suspicious_devices": suspicious_devices
        }
    
    def generate_usb_timeline(self, devices: List[Dict]) -> List[Dict]:
        """إنشاء خط زمني لاتصالات USB"""
        timeline = []
        
        for device in devices:
            timeline.append({
                "timestamp": device["first_connected"],
                "event": "first_connection",
                "device": f"{device['vendor']} {device['product']}",
                "serial": device["serial_number"]
            })
            
            timeline.append({
                "timestamp": device["last_connected"],
                "event": "last_connection",
                "device": f"{device['vendor']} {device['product']}",
                "serial": device["serial_number"]
            })
        
        # ترتيب الخط الزمني
        timeline.sort(key=lambda x: x["timestamp"])
        return timeline

# تهيئة المحلل
usb_analyzer = USBForensicsAnalyzer()

@app.get("/")
async def root():
    return {
        "message": "مرحباً في خدمة تحليل أجهزة USB",
        "version": "1.0.0"
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "usb_forensics"}

@app.get("/analyze/usb")
async def analyze_usb():
    """تحليل أجهزة USB المتصلة"""
    return usb_analyzer.analyze_usb_devices()

@app.get("/timeline/usb")
async def usb_timeline():
    """الخط الزمني لاتصالات USB"""
    analysis = usb_analyzer.analyze_usb_devices()
    timeline = usb_analyzer.generate_usb_timeline(analysis["usb_devices"])
    
    return {
        "status": "success",
        "timeline_events": len(timeline),
        "timeline": timeline
    }

@app.get("/suspicious/usb")
async def suspicious_usb():
    """الأجهزة USB المشبوهة"""
    analysis = usb_analyzer.analyze_usb_devices()
    suspicious = analysis["suspicious_activity"]
    
    return {
        "suspicious_devices": suspicious["suspicious_devices"],
        "risk_level": suspicious["risk_level"],
        "total_suspicious": suspicious["suspicious_devices_count"]
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8016, log_level="info")
