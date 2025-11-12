from fastapi import FastAPI
from fastapi.responses import HTMLResponse
import uvicorn

app = FastAPI(title="FFactory Frontend")

HTML_CONTENT = """
<!DOCTYPE html>
<html>
<head>
    <title>FFactory TITAN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .container { max-width: 800px; margin: 0 auto; }
        .status { padding: 10px; margin: 10px 0; border-radius: 5px; }
        .healthy { background: #d4edda; color: #155724; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 FFactory TITAN</h1>
        <p>النظام الشامل للتحليل الجنائي الرقمي</p>
        
        <div class="status healthy">
            <strong>الحالة:</strong> النظام يعمل بشكل طبيعي
        </div>
        
        <h2>الخدمات النشطة:</h2>
        <ul>
            <li>🔍 Investigation API - نشط</li>
            <li>📊 Behavioral Analytics - نشط</li>
            <li>📁 Case Manager - نشط</li>
            <li>🗄️ Database - نشط</li>
            <li>🔮 Redis - نشط</li>
        </ul>
        
        <p><em>تم التهيئة بنجاح في: <!--TIMESTAMP--></em></p>
    </div>
</body>
</html>
"""

@app.get("/", response_class=HTMLResponse)
async def read_root():
    from datetime import datetime
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return HTML_CONTENT.replace("<!--TIMESTAMP-->", timestamp)

@app.get("/health")
async def health_check():
    return {"status": "healthy", "service": "frontend"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=3000)
