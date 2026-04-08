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


def _safe_name(name: str, base: Path) -> Path:
    """确保解析后的路径仍在 base 目录下，否则抛 400。"""
    target = (base / name).resolve()
    if not target.is_relative_to(base.resolve()):
        raise HTTPException(status_code=400, detail="非法文件名")
    return target


@app.get("/fonts")
def list_fonts():
    return [
        {"name": f.name, "size": f.stat().st_size}
        for f in sorted(FONTS_DIR.iterdir())
        if f.suffix.lower() in ALLOWED_FONT_EXTS
    ]


@app.post("/fonts")
async def upload_font(file: UploadFile):
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    safe_filename = Path(file.filename).name
    suffix = Path(safe_filename).suffix.lower()
    if suffix not in ALLOWED_FONT_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 .ttf / .otf 文件")
    dest = FONTS_DIR / safe_filename
    dest.write_bytes(await file.read())
    return {"name": safe_filename}


@app.delete("/fonts/{name}")
def delete_font(name: str):
    target = _safe_name(name, FONTS_DIR)
    if not target.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    target.unlink()
    return {"deleted": name}


@app.get("/screens")
def list_screens():
    return [
        {"name": f.name, "size": f.stat().st_size}
        for f in sorted(SCREENS_DIR.iterdir())
        if f.suffix.lower() in ALLOWED_SCREEN_EXTS
    ]


@app.post("/screens")
async def upload_screen(file: UploadFile):
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    safe_filename = Path(file.filename).name
    suffix = Path(safe_filename).suffix.lower()
    if suffix not in ALLOWED_SCREEN_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 .png 文件")
    dest = SCREENS_DIR / safe_filename
    dest.write_bytes(await file.read())
    return {"name": safe_filename}


@app.delete("/screens/{name}")
def delete_screen(name: str):
    target = _safe_name(name, SCREENS_DIR)
    if not target.exists():
        raise HTTPException(status_code=404, detail="文件不存在")
    target.unlink()
    return {"deleted": name}
