#!/usr/bin/env python3
"""把 qmd-src/*.qmd 编译成 dist/*.qmd（按 hashtab 把 identifier 替换为 hash 形式）。

用法:
    python3 tools/hash-qmd.py qmd-src/advanced_panel.qmd > dist/advanced_panel.qmd

hashtab 二进制格式:
    repeat:
        u64 BE  hash
        u32 BE  len
        bytes   identifier (utf-8, len 字节)

替换规则:
    AFFECT/TRAVERSE/LOCATE 行  →  identifier 用 [[hash]] 形式
    INSERT { ... } 块内部     →  identifier 用 ~&hash&~ 形式
                                  字符串字面量若整体命中 hashtab 则用 ~&"hash&~ 形式
    未在 hashtab 中出现的 token 原样保留（例如 _rmhAdvancedPanel、function、注释等）。
"""
from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

HASHTAB_PATH = Path(__file__).parent / "hashtab"

STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
PATH_RE = re.compile(r"/[^\s\[\]]+\.qml")

# QMLDIFF 关键字 + JS 控制流 + QML 类型关键字: 永不替换
# QML 类型关键字 (string/int/bool/real/...) 既不能作为 identifier hash (会破坏 property 声明),
# 也不能作为字符串字面量 hash (会破坏 typeof xxx === "string" 这种比较表达式).
KEYWORDS = {
    "AFFECT", "TRAVERSE", "LOCATE", "INSERT", "END",
    "BEFORE", "AFTER", "ALL",
    "signal", "property", "function", "var", "let", "const",
    "if", "else", "for", "while", "do",
    "return", "break", "continue",
    "try", "catch", "throw", "finally",
    "new", "this", "void", "typeof", "instanceof", "in", "of",
    "switch", "case", "default",
    # QML 基本类型
    "string", "int", "bool", "real", "double", "url", "color",
    "date", "point", "rect", "size", "font", "vector2d", "vector3d",
    "vector4d", "matrix4x4", "quaternion", "alias",
    # JS 字面值
    "true", "false", "null", "undefined", "NaN", "Infinity",
}


def load_hashtab(path: Path) -> dict[str, int]:
    table: dict[str, int] = {}
    data = path.read_bytes()
    pos = 0
    while pos + 12 <= len(data):
        (h,) = struct.unpack(">Q", data[pos:pos + 8])
        (n,) = struct.unpack(">I", data[pos + 8:pos + 12])
        end = pos + 12 + n
        if end > len(data):
            break
        try:
            ident = data[pos + 12:end].decode("utf-8")
        except UnicodeDecodeError:
            ident = data[pos + 12:end].decode("latin-1")
        # 跳过 header 占位（hash=0）和版本号
        if h != 0 and ident:
            table[ident] = h
        pos = end
    return table


def _replace_idents(text: str, table: dict[str, int], wrap: str) -> str:
    """对 text 里的 identifier 做 hash 替换。wrap='[[%d]]' 或 '~&%d&~'。"""
    def repl(m: re.Match[str]) -> str:
        s = m.group(0)
        if s in KEYWORDS:
            return s
        if s in table:
            return wrap % table[s]
        return s
    return IDENT_RE.sub(repl, text)


def hash_header_line(text: str, table: dict[str, int]) -> str:
    """处理 AFFECT/TRAVERSE/LOCATE 这一类外层行。"""
    def repl_path(m: re.Match[str]) -> str:
        s = m.group(0)
        return f"[[{table[s]}]]" if s in table else s
    text = PATH_RE.sub(repl_path, text)
    return _replace_idents(text, table, "[[%d]]")


def hash_insert_body(text: str, table: dict[str, int]) -> str:
    """处理 INSERT { ... } 内部一行。"""
    placeholders: list[str] = []

    def stash_string(m: re.Match[str]) -> str:
        s = m.group(0)
        inner = s[1:-1]
        # KEYWORDS 内的字符串 (如 typeof x === "string") 是 JS 类型名比较, 不能 hash
        if inner in table and inner not in KEYWORDS:
            replaced = f"~&\"{table[inner]}&~"
        else:
            replaced = s
        placeholders.append(replaced)
        return f"\x00STR{len(placeholders) - 1}\x00"

    text = STRING_RE.sub(stash_string, text)
    text = _replace_idents(text, table, "~&%d&~")

    def restore(m: re.Match[str]) -> str:
        return placeholders[int(m.group(1))]

    text = re.sub(r"\x00STR(\d+)\x00", restore, text)
    return text


def compile_qmd(src: str, table: dict[str, int]) -> str:
    out: list[str] = []
    insert_depth = 0
    for line in src.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(";"):
            out.append(line)
            continue

        if insert_depth == 0:
            if stripped.startswith("INSERT"):
                # INSERT { 这行外层不 hash，但内部有 { 时进入 insert 模式
                opens = line.count("{") - line.count("}")
                out.append(line)
                if opens > 0:
                    insert_depth = opens
            elif stripped.startswith("REPLACE"):
                # REPLACE Component WITH { ... }
                # 行本身的 Component 要按 header 形式 hash, 但 { 之后进入 body 模式 (跟 INSERT 一样, body 内部用 ~&hash&~)
                opens = line.count("{") - line.count("}")
                out.append(hash_header_line(line, table))
                if opens > 0:
                    insert_depth = opens
            else:
                out.append(hash_header_line(line, table))
            continue

        # 在 INSERT 块内
        # 注意 hash 后的字符串里可能含 { } —— 用 hash_insert_body 之前先数原始 brace
        opens = line.count("{") - line.count("}")
        hashed = hash_insert_body(line, table)
        out.append(hashed)
        insert_depth += opens
        if insert_depth < 0:
            insert_depth = 0

    return "\n".join(out) + "\n"


def main() -> None:
    if len(sys.argv) != 2:
        print("用法: hash-qmd.py <qmd-src/file.qmd>", file=sys.stderr)
        sys.exit(2)
    src_path = Path(sys.argv[1])
    table = load_hashtab(HASHTAB_PATH)
    text = src_path.read_text(encoding="utf-8")
    sys.stdout.write(compile_qmd(text, table))


if __name__ == "__main__":
    main()
