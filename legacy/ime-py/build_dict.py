# ime/build_dict.py
"""从 Unicode CJK 基本区生成拼音→汉字映射表 chars.json"""
import json
from pathlib import Path

from pypinyin import pinyin, Style

OUTPUT = Path(__file__).parent / "dict" / "chars.json"

# CJK 统一汉字基本区 U+4E00 – U+9FFF
CJK_START = 0x4E00
CJK_END = 0x9FFF


def build() -> dict[str, list[str]]:
    table: dict[str, list[str]] = {}
    for cp in range(CJK_START, CJK_END + 1):
        char = chr(cp)
        # lazy_pinyin 对多音字只取第一个读音，够用
        results = pinyin(char, style=Style.NORMAL, heteronym=False)
        if not results:
            continue
        py = results[0][0]
        if not py or not py.isalpha():
            continue
        table.setdefault(py, []).append(char)
    return table


def main() -> None:
    print("正在生成拼音词库…")
    table = build()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(table, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"词库已写入 {OUTPUT}，共 {len(table)} 个拼音条目")


if __name__ == "__main__":
    main()
