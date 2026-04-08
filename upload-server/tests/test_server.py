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
