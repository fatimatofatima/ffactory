from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from transformers import AutoTokenizer, AutoModelForTokenClassification, pipeline
import torch
import os

app = FastAPI(title="Neural Core - Multi-Dialect NLP Engine")

# FFIX: تعريف النماذج عالمياً
ARABERT_NER_PIPELINE = None
MBERT_NER_PIPELINE = None # للغات المتعددة والأمازيغية

class AnalysisRequest(BaseModel):
    text: str 
    lang_model: str = "ar" # 'ar' for Arabic/Dialects, 'multi' for Tamazight/Multilingual

app = FastAPI(title="Neural Core - Multi-Dialect NLP Engine")

def log(msg):
    print(f"[NLP Core] {msg}", flush=True)

@app.on_event("startup")
async def startup_event():
    global ARABERT_NER_PIPELINE, MBERT_NER_PIPELINE
    log("بدء تحميل نماذج NLP...")
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # 1. تحميل AraBERT (للغة العربية الفصحى والدارجة المغربية/المشرقية)
    try:
        log("🟢 تحميل AraBERT NER (للدارجة/الفصحى).")
        # نموذج NER مدرب على محتوى عربي متنوع
        model_name = "CAMeL-Lab/bert-base-arabic-camel-msa-ner"
        tokenizer = AutoTokenizer.from_pretrained(model_name)
        model = AutoModelForTokenClassification.from_pretrained(model_name).to(device)
        ARABERT_NER_PIPELINE = pipeline(
            "ner", model=model, tokenizer=tokenizer, device=0 if device.type == "cuda" else -1
        )
    except Exception as e:
        log(f"🔴 فشل تحميل AraBERT: {e}")

    # 2. تحميل MBERT (للغات المتعددة والأمازيغية)
    try:
        log("🟡 تحميل MBERT (للتغطية المتعددة/الأمازيغية).")
        # نموذج Multilingual BERT (يغطي 104 لغات، بما في ذلك اللاتينية والأحرف العربية)
        model_name = "bert-base-multilingual-cased"
        tokenizer_m = AutoTokenizer.from_pretrained(model_name)
        model_m = AutoModelForTokenClassification.from_pretrained('davidsbatista/mdeberta-v3-base-ner-wikiann').to(device)
        MBERT_NER_PIPELINE = pipeline(
            "ner", model=model_m, tokenizer=tokenizer_m, device=0 if device.type == "cuda" else -1, aggregation_strategy="simple"
        )
    except Exception as e:
        log(f"🔴 فشل تحميل MBERT: {e}")


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "service": "neural-core",
        "ar_status": "READY" if ARABERT_NER_PIPELINE else "FAILED/PENDING",
        "multi_status": "READY" if MBERT_NER_PIPELINE else "FAILED/PENDING"
    }

@app.post("/analyze/ner")
async def analyze_ner(req: AnalysisRequest):
    pipeline_to_use = None
    
    if req.lang_model == 'ar' and ARABERT_NER_PIPELINE:
        pipeline_to_use = ARABERT_NER_PIPELINE
        model_info = "AraBERT NER (Arabic/Dialects)"
    elif req.lang_model == 'multi' and MBERT_NER_PIPELINE:
        pipeline_to_use = MBERT_NER_PIPELINE
        model_info = "MBERT NER (Multilingual/Tamazight)"
    else:
        raise HTTPException(status_code=503, detail=f"النموذج {req.lang_model} غير متاح أو قيد التحميل. حالة النموذج العربي: {ARABERT_NER_PIPELINE is not None}, حالة المتعدد: {MBERT_NER_PIPELINE is not None}")

    try:
        # تنفيذ استخراج الكيانات المسماة (NER)
        results = pipeline_to_use(req.text)
        
        # تصفية وإرجاع النتائج
        return {
            "status": "success",
            "model": model_info,
            "entities": results
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"فشل التحليل اللغوي: {e}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
