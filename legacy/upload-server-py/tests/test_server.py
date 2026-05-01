import pytest
from httpx import AsyncClient, ASGITransport
from pathlib import Path

@pytest.fixture
def fonts_dir(tmp_path):
    return tmp_path / "fonts"

@pytest.fixture
def app_with_dirs(fonts_dir, tmp_path):
    import importlib
    import sys

    fonts_dir.mkdir(exist_ok=True)
    screens_dir = tmp_path / "screens"
    screens_dir.mkdir()

    # 确保每次测试重新加载模块，避免全局状态污染
    if "main" in sys.modules:
        del sys.modules["main"]

    sys.path.insert(0, str(Path(__file__).parent.parent))
    import main as m
    m.FONTS_DIR = fonts_dir
    m.SCREENS_DIR = screens_dir
    return m.app

@pytest.mark.asyncio
async def test_list_fonts_empty(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/fonts")
    assert resp.status_code == 200
    assert resp.json() == []

@pytest.mark.asyncio
async def test_upload_font(app_with_dirs, fonts_dir):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/fonts",
            files={"file": ("MiSans.ttf", b"fake-font-data", "application/octet-stream")}
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "MiSans.ttf"
    assert (fonts_dir / "MiSans.ttf").exists()

@pytest.mark.asyncio
async def test_delete_font(app_with_dirs, fonts_dir):
    (fonts_dir / "OldFont.ttf").write_bytes(b"data")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.delete("/fonts/OldFont.ttf")
    assert resp.status_code == 200
    assert not (fonts_dir / "OldFont.ttf").exists()

@pytest.mark.asyncio
async def test_delete_font_not_found(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.delete("/fonts/nonexistent.ttf")
    assert resp.status_code == 404

@pytest.mark.asyncio
async def test_path_traversal_upload_blocked(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/fonts",
            files={"file": ("../evil.ttf", b"data", "application/octet-stream")}
        )
    # ../evil.ttf 的 Path(...).name 应该变成 evil.ttf，不会逃出目录
    assert resp.status_code == 200
    assert resp.json()["name"] == "evil.ttf"

@pytest.mark.asyncio
async def test_path_traversal_delete_blocked(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.delete("/fonts/..%2Fevil")
    assert resp.status_code in (400, 404)

@pytest.mark.asyncio
async def test_list_screens_empty(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/screens")
    assert resp.status_code == 200
    assert resp.json() == []

@pytest.mark.asyncio
async def test_upload_screen(app_with_dirs, tmp_path):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/screens",
            files={"file": ("sleep.png", b"\x89PNG\r\n", "image/png")}
        )
    assert resp.status_code == 200
    assert resp.json()["name"] == "sleep.png"

@pytest.mark.asyncio
async def test_upload_screen_wrong_format(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/screens",
            files={"file": ("image.jpg", b"jpeg-data", "image/jpeg")}
        )
    assert resp.status_code == 400

@pytest.mark.asyncio
async def test_delete_screen(app_with_dirs, tmp_path):
    import sys
    if "main" in sys.modules:
        import main as m
        screens = m.SCREENS_DIR
    else:
        screens = tmp_path / "screens"
    (screens / "old.png").write_bytes(b"data")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.delete("/screens/old.png")
    assert resp.status_code == 200

@pytest.mark.asyncio
async def test_path_traversal_screen_delete_blocked(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.delete("/screens/..%2Fevil")
    assert resp.status_code in (400, 404)


# ---- 文档上传（通过 xovi-message-broker 调 librarian importDocument）----

@pytest.fixture
def fake_librarian(monkeypatch, tmp_path):
    """模拟 _invoke_librarian, 记录调用参数并按预设响应返回。"""
    import main as m
    # 把 staging dir 重定向到 tmp_path，避免依赖 /tmp/rmkit_upload
    staging = tmp_path / "staging"
    staging.mkdir()
    monkeypatch.setattr(m, "DOC_STAGING_DIR", staging)

    class _Stub:
        last_signal = None
        last_value = None
        last_staged_bytes = None
        response = "abc-uuid-123"
        raise_exc = None

    def _fake(signal, value, timeout=60.0):
        _Stub.last_signal = signal
        _Stub.last_value = value
        # 读出 staging 文件内容供断言
        try:
            _Stub.last_staged_bytes = Path(value).read_bytes()
        except OSError:
            _Stub.last_staged_bytes = None
        if _Stub.raise_exc is not None:
            raise _Stub.raise_exc
        return _Stub.response

    monkeypatch.setattr(m, "_invoke_librarian", _fake)
    return _Stub


@pytest.mark.asyncio
async def test_upload_document_pdf(app_with_dirs, fake_librarian):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("book.pdf", b"%PDF-1.4 fake", "application/pdf")},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "book.pdf"
    assert body["size"] == len(b"%PDF-1.4 fake")
    assert body["uuid"] == "abc-uuid-123"
    assert fake_librarian.last_signal == "importDocument"
    assert fake_librarian.last_value.endswith("_book.pdf")
    assert fake_librarian.last_staged_bytes == b"%PDF-1.4 fake"


@pytest.mark.asyncio
async def test_upload_document_epub(app_with_dirs, fake_librarian):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("novel.epub", b"PK\x03\x04", "application/epub+zip")},
        )
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_upload_document_rejects_other_ext(app_with_dirs, fake_librarian):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("evil.exe", b"MZ", "application/octet-stream")},
        )
    assert resp.status_code == 400
    # 不应触达 librarian
    assert fake_librarian.last_signal is None


@pytest.mark.asyncio
async def test_upload_document_pipe_missing(app_with_dirs, fake_librarian):
    fake_librarian.raise_exc = RuntimeError("/run/xovi-mb 不存在 (xovi-message-broker 未启用?)")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("book.pdf", b"x", "application/pdf")},
        )
    assert resp.status_code == 503
    assert "xovi-message-broker" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_upload_document_timeout(app_with_dirs, fake_librarian):
    fake_librarian.raise_exc = TimeoutError("librarian 无响应 (signal=importDocument)")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("book.pdf", b"x", "application/pdf")},
        )
    assert resp.status_code == 503
    assert "无响应" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_upload_document_librarian_error(app_with_dirs, fake_librarian):
    fake_librarian.response = "ERROR: file does not exist: /tmp/foo"
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.post(
            "/documents",
            files={"file": ("book.pdf", b"x", "application/pdf")},
        )
    assert resp.status_code == 500
    assert resp.json()["detail"].startswith("ERROR:")


@pytest.mark.asyncio
async def test_qr_page_served(app_with_dirs):
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/qr")
    assert resp.status_code == 200
    assert "上传到 reMarkable" in resp.text


@pytest.mark.asyncio
async def test_qr_info_with_wifi(app_with_dirs, monkeypatch):
    import main as m
    monkeypatch.setattr(m, "_detect_lan_ip", lambda: "192.168.1.42")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/qr-info")
    assert resp.status_code == 200
    body = resp.json()
    assert body["available"] is True
    assert body["ip"] == "192.168.1.42"
    assert body["url"] == "http://192.168.1.42:8080/qr"


@pytest.mark.asyncio
async def test_qr_info_no_wifi(app_with_dirs, monkeypatch):
    import main as m
    monkeypatch.setattr(m, "_detect_lan_ip", lambda: None)
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/qr-info")
    assert resp.status_code == 200
    assert resp.json()["available"] is False


@pytest.mark.asyncio
async def test_qr_png(app_with_dirs, monkeypatch):
    import main as m
    monkeypatch.setattr(m, "_detect_lan_ip", lambda: "192.168.1.42")
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/qr.png")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
    assert resp.content[:8] == b"\x89PNG\r\n\x1a\n"


@pytest.mark.asyncio
async def test_qr_png_no_wifi(app_with_dirs, monkeypatch):
    import main as m
    monkeypatch.setattr(m, "_detect_lan_ip", lambda: None)
    async with AsyncClient(transport=ASGITransport(app=app_with_dirs), base_url="http://test") as client:
        resp = await client.get("/qr.png")
    assert resp.status_code == 503
