from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path

app = FastAPI()

FONTS_DIR = Path.home() / ".local/share/rmkit-cn/fonts"
SCREENS_DIR = Path.home() / ".local/share/rmkit-cn/screens"

FONTS_DIR.mkdir(parents=True, exist_ok=True)
SCREENS_DIR.mkdir(parents=True, exist_ok=True)

ALLOWED_FONT_EXTS = {".ttf", ".otf"}
ALLOWED_SCREEN_EXTS = {".png"}


@app.get("/fonts")
def list_fonts():
    return [
        {"name": f.name, "size": f.stat().st_size}
        for f in sorted(FONTS_DIR.iterdir())
        if f.suffix.lower() in ALLOWED_FONT_EXTS
    ]


@app.post("/fonts")
async def upload_font(file: UploadFile):
    suffix = Path(file.filename).suffix.lower()
    if suffix not in ALLOWED_FONT_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 .ttf / .otf 文件")
    dest = FONTS_DIR / file.filename
    dest.write_bytes(await file.read())
    return {"name": file.filename}


@app.delete("/fonts/{name}")
def delete_font(name: str):
    target = FONTS_DIR / name
    if not target.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    target.unlink()
    return {"deleted": name}
