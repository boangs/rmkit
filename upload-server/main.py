import asyncio
import io
import os
import select
import socket
import time
import uuid as uuid_lib

import segno
from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pathlib import Path

UPLOAD_PORT = 8080

app = FastAPI()

FONTS_DIR = Path.home() / ".local/share/rmkit-cn/fonts"
SCREENS_DIR = Path.home() / ".local/share/rmkit-cn/screens"
DOC_STAGING_DIR = Path("/tmp/rmkit_upload")

FONTS_DIR.mkdir(parents=True, exist_ok=True)
SCREENS_DIR.mkdir(parents=True, exist_ok=True)
DOC_STAGING_DIR.mkdir(parents=True, exist_ok=True)

ALLOWED_FONT_EXTS = {".ttf", ".otf"}
ALLOWED_SCREEN_EXTS = {".png"}
ALLOWED_DOC_EXTS = {".pdf", ".epub"}

XOVI_MB_IN = "/run/xovi-mb"
XOVI_MB_OUT = "/run/xovi-mb-out"
LIBRARIAN_TIMEOUT = 60.0


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


def _invoke_librarian(signal: str, value: str, timeout: float = LIBRARIAN_TIMEOUT) -> str:
    """通过 /run/xovi-mb 调用 librarian, 返回 stdout (uuid 或 'ERROR: ...')。

    协议见 xovi-message-broker/README.MD: '>e<signal>:<value>\\n' 写入 IN 管道,
    broker 处理完后开 OUT 管道写返回值. broker 串行处理每条命令, 因此 client 必须
    先写完命令再打开 OUT, 否则 broker 的 open(O_WRONLY) 会先于我们 open(O_RDONLY)
    导致 broker 永久阻塞.
    """
    if not Path(XOVI_MB_IN).exists():
        raise RuntimeError(f"{XOVI_MB_IN} 不存在 (xovi-message-broker 未启用?)")

    cmd = f">e{signal}:{value}\n".encode("utf-8")

    # 1) 先写命令 → broker 拿到后会去 open OUT_PIPE 阻塞等读端
    with open(XOVI_MB_IN, "wb") as f:
        f.write(cmd)

    # 2) 非阻塞 open 读端, 用 select 等数据 / EOF
    fd = os.open(XOVI_MB_OUT, os.O_RDONLY | os.O_NONBLOCK)
    try:
        deadline = time.monotonic() + timeout
        chunks: list[bytes] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"librarian 无响应 (signal={signal})")
            r, _, _ = select.select([fd], [], [], remaining)
            if not r:
                continue
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                # writer 已关闭, 数据读完
                break
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", errors="replace")
    finally:
        os.close(fd)


@app.post("/documents")
async def upload_document(file: UploadFile):
    if not file.filename:
        raise HTTPException(status_code=400, detail="文件名不能为空")
    safe_filename = Path(file.filename).name
    suffix = Path(safe_filename).suffix.lower()
    if suffix not in ALLOWED_DOC_EXTS:
        raise HTTPException(status_code=400, detail="仅支持 .pdf / .epub 文件")

    content = await file.read()
    staging_path = DOC_STAGING_DIR / f"{uuid_lib.uuid4().hex}_{safe_filename}"
    staging_path.write_bytes(content)

    try:
        try:
            result = await asyncio.to_thread(
                _invoke_librarian, "importDocument", str(staging_path)
            )
        except FileNotFoundError as exc:
            raise HTTPException(
                status_code=503,
                detail=f"xovi-message-broker 管道不存在: {exc}",
            ) from exc
        except (RuntimeError, TimeoutError) as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
    finally:
        # librarian 已把文件 copy 到 xochitl 数据目录, staging 文件可清理
        staging_path.unlink(missing_ok=True)

    result = result.strip()
    if result.startswith("ERROR:"):
        raise HTTPException(status_code=500, detail=result)
    if not result:
        raise HTTPException(status_code=500, detail="librarian 返回空")
    return {"name": safe_filename, "size": len(content), "uuid": result}


app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")


@app.get("/", response_class=FileResponse)
def index():
    return str(Path(__file__).parent / "static/index.html")


@app.get("/qr", response_class=FileResponse)
def qr_page():
    return str(Path(__file__).parent / "static/qr.html")


def _detect_lan_ip() -> str | None:
    """探测设备在局域网（非 USB）上的 IP。返回 None 表示无可用 WiFi。"""
    candidates: list[str] = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip.startswith("127.") or ip.startswith("10.11.99."):
                continue
            candidates.append(ip)
    except socket.gaierror:
        pass

    if not candidates:
        # 兜底：用 UDP socket 拿默认路由源 IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            if not ip.startswith("127.") and not ip.startswith("10.11.99."):
                candidates.append(ip)
        except OSError:
            pass
        finally:
            s.close()

    return candidates[0] if candidates else None


@app.get("/qr-info")
def qr_info():
    ip = _detect_lan_ip()
    if not ip:
        return {"available": False, "reason": "未检测到 Wi-Fi 网络"}
    url = f"http://{ip}:{UPLOAD_PORT}/qr"
    return {"available": True, "ip": ip, "port": UPLOAD_PORT, "url": url}


@app.get("/qr.png")
def qr_png():
    ip = _detect_lan_ip()
    if not ip:
        raise HTTPException(status_code=503, detail="未检测到 Wi-Fi 网络")
    url = f"http://{ip}:{UPLOAD_PORT}/qr"
    qr = segno.make(url, error="m")
    buf = io.BytesIO()
    qr.save(buf, kind="png", scale=8, border=2)
    return Response(content=buf.getvalue(), media_type="image/png")
