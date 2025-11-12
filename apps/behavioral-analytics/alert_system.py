from datetime import datetime
import json
from typing import Dict, List
from kafka import KafkaProducer
from .detection_engine import AdvancedBehavioralAnalytics 
import hashlib
import os

class IntelligentAlertSystem:
    def __init__(self, kafka_broker: str = 'kafka:9092'):
        self.kafka_producer = KafkaProducer(
            bootstrap_servers=[kafka_broker],
            value_serializer=lambda v: json.dumps(v).encode('utf-8')
        )
        self.analyzer = AdvancedBehavioralAnalytics()
        self.evidence_storage_path = "/mnt/minio/evidence_vault" # مسار تخزين الأدلة (على MinIO)

    def _generate_chain_of_custody_hash(self, data: str) -> str:
        """يولد قيمة تجزئة (Hash) لضمان سلامة الدليل."""
        return hashlib.sha256(data.encode('utf-8')).hexdigest()

    def preserve_evidence(self, user_events: List[Dict], alert_id: str) -> Dict:
        """
        محاكاة عملية الحفظ الجنائي للأدلة.
        تُنشئ ملفاً يمثل الدليل وتُنشئ سجل سلسلة الحضانة.
        """
        # 1. تحديد الدليل الرقمي الخام (Raw Digital Evidence)
        raw_evidence = json.dumps(user_events, indent=2)
        
        # 2. توليد قيمة تجزئة للدليل (Hash/Integrity Check)
        evidence_hash = self._generate_chain_of_custody_hash(raw_evidence)
        
        # 3. محاكاة تخزين الدليل (على فرض أن المسار موجود ويشير لـ MinIO)
        evidence_filename = f"{alert_id}_raw_events.json"
        # os.makedirs(self.evidence_storage_path, exist_ok=True)
        # with open(os.path.join(self.evidence_storage_path, evidence_filename), "w") as f:
        #     f.write(raw_evidence)
        
        # 4. بناء سجل سلسلة الحضانة (Chain of Custody Log)
        custody_log = {
            "acquisition_id": alert_id,
            "acquisition_time": datetime.utcnow().isoformat(),
            "data_source": "Behavioral Event Stream",
            "storage_location": f"MinIO-Bucket/{alert_id}/",
            "integrity_hash_sha256": evidence_hash,
            "custodian_log": [
                {"timestamp": datetime.utcnow().isoformat(), "action": "Automatic Acquisition by Behavioral Engine", "custodian": "System"}
            ]
        }
        
        return custody_log

    def publish_alert(self, alert: Dict):
        """إرسال التنبيه إلى Kafka (ترك النشر مُعلقًا مؤقتًا)."""
        # self.kafka_producer.send('behavioral_alerts', alert)
        pass # نُعلق الإرسال الحقيقي لضمان التركيز على البنية

    def generate_behavioral_alert(self, analysis_result: Dict, user_events: List[Dict]) -> Dict:
        """توليد تنبيهات سلوكية ذكية وربطها بسلسلة الحضانة."""
        
        alert_id = f"BEHAV_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        
        # 1. حفظ الدليل وإنشاء سلسلة الحضانة
        custody_record = self.preserve_evidence(user_events, alert_id)
        
        # 2. بناء التنبيه
        alert = {
            "alert_id": alert_id,
            "user_id": user_events[0].get('user_id'),
            "confidence_score": analysis_result["risk_score"] / 100,
            "timestamp": datetime.utcnow().isoformat(),
            "detected_patterns": analysis_result["detected_patterns"],
            "anomaly_score": analysis_result["anomaly_score"],
            "severity": "CRITICAL" if analysis_result["risk_score"] >= 70 else "HIGH",
            "chain_of_custody": custody_record, # دمج سجل الحضانة هنا
            "recommended_investigation": analysis_result["recommended_actions"]
        }
        
        self.publish_alert(alert)
        return alert

    def process_events_and_alert(self, user_events: List[Dict], asset_sensitivity: str = "LOW") -> Dict:
        """معالجة الأحداث وتوليد التنبيهات الذكية."""
        if not user_events:
            return {"status": "ERROR", "message": "No events provided."}
            
        analysis_result = self.analyzer.analyze_user_behavior(user_events, asset_sensitivity)
        
        if analysis_result["risk_score"] >= 40: # حد التنبيه
            return self.generate_behavioral_alert(analysis_result, user_events)
        
        return {"status": "OK", "message": "Risk score below threshold.", "risk_score": analysis_result["risk_score"]}
