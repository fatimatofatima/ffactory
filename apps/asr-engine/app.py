from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional, List, Dict
import os, requests, tempfile, math
from faster_whisper import WhisperModel

api=FastAPI(title="FFactory ASR")
ASR_MODEL=os.getenv("MODEL_SIZE","medium")
LANG=os.getenv("LANGUAGE")
HF=os.getenv("HUGGINGFACE_TOKEN","").strip()

model=WhisperModel(ASR_MODEL, device="cpu", compute_type="int8")

# diarization lazy
_diar=None
def get_diar():
    global _diar
    if _diar is not None: return _diar
    if not HF: return None
    from pyannote.audio import Pipeline
    _diar = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=HF)
    return _diar

@api.get("/health")
def health():
    return {"status":"ok","model":ASR_MODEL,"lang":LANG,"diarization":bool(HF)}

class TranscribeIn(BaseModel):
    audio_url:str
    language: Optional[str]=None
    diarize: Optional[bool]=False

@api.post("/transcribe")
def transcribe(inp:TranscribeIn):
    try:
        r=requests.get(inp.audio_url, timeout=60); r.raise_for_status()
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(r.content); f.flush()
            segs, info = model.transcribe(
                f.name,
                language=inp.language or LANG,
                vad_filter=True, vad_parameters=dict(min_silence_duration_ms=300),
                word_timestamps=True, beam_size=5
            )
            segments=[]
            words=[]
            for s in segs:
                segments.append({
                    "start": float(s.start or 0.0),
                    "end": float(s.end or 0.0),
                    "text": s.text.strip(),
                    "avg_logprob": getattr(s, "avg_logprob", None),
                    "no_speech_prob": getattr(s, "no_speech_prob", None),
                })
                if s.words:
                    for w in s.words:
                        words.append({"start": float(w.start or 0.0),
                                      "end": float(w.end or 0.0),
                                      "word": w.word})
            out={"language": info.language, "duration": float(info.duration or 0.0),
                 "text":"".join(s["text"] for s in segments).strip(),
                 "segments": segments, "words": words}

            if inp.diarize and HF:
                diar = get_diar()
                res = diar(f.name)
                spk=[]
                for turn, track, label in res.itertracks(yield_label=True):
                    spk.append({"start": float(turn.start), "end": float(turn.end), "speaker": label})
                # greedy alignment words -> speakers by overlap
                for w in out["words"]:
                    mid=(w["start"]+w["end"])/2.0
                    owners=[s for s in spk if s["start"]<=mid<=s["end"]]
                    if owners: w["speaker"]=owners[0]["speaker"]
                out["speakers"]=spk
            return out
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
