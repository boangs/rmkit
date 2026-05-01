#!/usr/bin/env python3
"""扫描 qmd/*.qmd 里的 hash 引用, 校验它们都在 tools/hashtabs/ 下任一 hashtab 命中.

孤儿 hash 会导致 qmldiff Rust panic → xochitl crash → A/B 切换 (历史事故).
本脚本作为 CI 的 pre-flight 校验, 防止再次部署带孤儿 hash 的 qmd.

用法:
    python3 tools/qmd_hash_check.py
退出码:
    0  全部命中
    1  发现孤儿 hash
    2  环境/路径问题
"""
from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HASHTAB_DIR = ROOT / "tools" / "hashtabs"
QMD_DIR = ROOT / "qmd"

# qmd 里的 hash 形式 (与 tools/hash-qmd.py 输出一致):
# - [[1234567890123456789]]   AFFECT / TRAVERSE / LOCATE 行
# - ~&1234567890123456789&~   INSERT 块内部 identifier
# - ~&"1234567890123456789&~  INSERT 块内部字符串 (注意末尾不是 &"~)
# 19 位左右 u64, 这里宽松 15~21 位.
HASH_RE = re.compile(r'(?:\[\[|~&"?)(\d{15,21})(?:\]\]|&~)')


def load_hashtab(path: Path) -> set[int]:
    hashes: set[int] = set()
    data = path.read_bytes()
    pos = 0
    while pos + 12 <= len(data):
        (h,) = struct.unpack(">Q", data[pos:pos + 8])
        (n,) = struct.unpack(">I", data[pos + 8:pos + 12])
        end = pos + 12 + n
        if end > len(data):
            break
        # 跳过 header 占位 (hash=0)
        if h != 0:
            hashes.add(h)
        pos = end
    return hashes


def main() -> int:
    if not HASHTAB_DIR.is_dir():
        print(f"FATAL: {HASHTAB_DIR} 不存在", file=sys.stderr)
        return 2

    print(f"=== 加载 hashtabs (来自 {HASHTAB_DIR.relative_to(ROOT)}) ===")
    union: set[int] = set()
    table_count = 0
    for f in sorted(HASHTAB_DIR.glob("hashtab-*")):
        h = load_hashtab(f)
        union |= h
        table_count += 1
        print(f"  {f.name:50s} {len(h):>6d} hashes")
    if table_count == 0:
        print("FATAL: tools/hashtabs/ 下没有 hashtab-* 文件", file=sys.stderr)
        return 2
    print(f"  合并: {len(union)} unique hashes")

    if not QMD_DIR.is_dir():
        print(f"WARN: {QMD_DIR.relative_to(ROOT)} 不存在, 跳过 qmd 校验")
        return 0

    qmd_files = sorted(QMD_DIR.glob("*.qmd"))
    if not qmd_files:
        print(f"WARN: {QMD_DIR.relative_to(ROOT)}/*.qmd 为空, 跳过校验")
        return 0

    print(f"\n=== 校验 qmd hash 命中 ({len(qmd_files)} files) ===")
    bad = 0
    for qmd in qmd_files:
        text = qmd.read_text(errors="replace")
        seen: set[int] = set()
        orphans: list[int] = []
        for m in HASH_RE.finditer(text):
            h = int(m.group(1))
            if h in seen:
                continue
            seen.add(h)
            if h not in union:
                orphans.append(h)
        rel = qmd.relative_to(ROOT)
        if orphans:
            bad += 1
            print(f"  ✗ {rel}  (孤儿 {len(orphans)}/{len(seen)})")
            for h in orphans:
                print(f"      ORPHAN {h}")
        else:
            print(f"  ✓ {rel}  ({len(seen)} hash 命中)")

    if bad:
        print(f"\n*** {bad} 个 qmd 文件含孤儿 hash ***")
        print("修复: 移到 qmd/_obsolete/, 或 rebuild_hashtable on device 后重新生成快照")
        return 1
    print("\nALL OK — 所有 qmd hash 校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
