"""
FFactory Behavioral Ontology - الأنطولوجيا المتقدمة للتحليل السلوكي
"""
# مخطط موحد للأحداث - لتسهيل معالجة البيانات
EVENT_SCHEMA = {
    "FILE_ACCESS": ["read", "write", "delete", "rename"],
    "NETWORK_COMMUNICATION": ["tcp", "udp", "http", "https"],
    "PROCESS_EXECUTION": ["powershell", "cmd", "bash", "service_start"],
    "AUTHENTICATION": ["login_success", "login_failure", "session_start"]
}

BEHAVIORAL_ONTOLOGY = {
    # السلوكيات المضادة للتحليل الجنائي
    "AntiForensicBehaviors": {
        "DATA_CONCEALMENT": [
            "RAPID_FILE_ENCRYPTION", "MASS_FILE_DELETION", "LOG_CLEARING",
            "METADATA_TAMPERING", "FILE_SHREDDING_ATTEMPTS"
        ],
        "IDENTITY_MASKING": [
            "MULTIPLE_USER_SESSIONS", "UNUSUAL_LOGIN_LOCATIONS",
            "SERVICE_ACCOUNT_ABUSE", "PRIVILEGE_ESCALATION_ATTEMPT"
        ]
    }
}
