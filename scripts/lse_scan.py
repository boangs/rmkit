#!/usr/bin/env python3
"""扫 aarch64 二进制里「裸露」的 LSE 原子指令 —— Paper Pro (ferrari, Cortex-A53) 执行即 SIGILL。

退出码: 0 = 干净, 1 = 有裸露的 LSE, 2 = 用法/环境问题。

为什么不能只看符号名
--------------------
第一版脚本按符号分类 (跳过 __aarch64_*, 只算 _Z* 的 C++ 符号), 对 .so 有效, 但对
strip 过的 Go 二进制会严重误判:

  * `-s -w` 把 __aarch64_cas4_acq 这类 local 符号抹掉了, objdump 只好把它们归到
    前一个还有名字的符号下 —— 于是 opencc::BinaryDict::SerializeToFile 名下凭空
    多出 9 条 "LSE", 实际是紧跟在它后面的 outline helper。按符号判就是假阳性。
  * 反过来, Go runtime 的 LSE 被归到 _start / crosscall2 / main 下 (700 条量级),
    按符号判又会漏掉真问题 —— 如果真有 C++ 代码也落在那几个名字下的话。

所以判据改成看指令本身的上下文。

什么样的 LSE 是安全的
--------------------
1. GCC 的 outline atomics helper —— 每条 LSE 前面都有运行时 CPU 能力判断:

       adrp x16, __aarch64_have_lse_atomics
       ldrb w16, [x16, #...]
       cbz  w16, <LL/SC 回退>     ← A53 从这里跳走
       casal w0, w1, [x2]         ← 只有支持 LSE 的 CPU 才执行到
       ret

2. Go runtime 自带的 —— Go 用 internal/cpu 做特性检测, 保护模式和 GCC 不同,
   但同样是运行时选路。实测纯 Go 产物 (space-server / ime-server) 在 ferrari 上
   一直正常, librime 版的 ime-server-rime 也是 (10-04 实测拼音五笔都可用)。

剩下的才是真危险: 编译器按 ARMv8.1+ 基线把 LSE 直接内联进普通函数体, 没有任何
回退路径。修法见 intercept/qml-inject/Makefile 的 ARCH_BASELINE。
"""

import re
import subprocess
import sys

# ARMv8.1 LSE 原子指令全集 (含各种 acquire/release/size 后缀)
LSE = re.compile(
    r"^(cas|casa|casab|casah|casal|casalb|casalh|casb|cash|casl|caslb|caslh"
    r"|casp|caspa|caspal|caspl"
    r"|swp|swpa|swpab|swpah|swpal|swpalb|swpalh|swpb|swph|swpl|swplb|swplh"
    r"|ldadd|ldadda|ldaddab|ldaddah|ldaddal|ldaddalb|ldaddalh|ldaddb|ldaddh|ldaddl|ldaddlb|ldaddlh"
    r"|ldclr|ldclra|ldclral|ldclrb|ldclrh|ldclrl"
    r"|ldeor|ldeora|ldeoral|ldeorb|ldeorh|ldeorl"
    r"|ldset|ldseta|ldsetal|ldsetb|ldseth|ldsetl"
    r"|ldsmax|ldsmaxa|ldsmaxal|ldsmaxl|ldsmin|ldsmina|ldsminal|ldsminl"
    r"|ldumax|ldumaxa|ldumaxal|ldumaxl|ldumin|ldumina|lduminal|lduminl"
    r"|stadd|staddl|stclr|stclrl|steor|steorl|stset|stsetl)$"
)

# Go 二进制 strip 之后符号所剩无几 —— 可能是 _start/main, 也可能整段都挂在 .text 下,
# 所以不能靠符号名认 Go 代码, 得先认出"这个文件是 Go 编的"。
GO_SYMS = ("_start", "crosscall2", "main", "_rt0_", "runtime.", "_cgo_", ".text")

# Go 工具链在二进制里埋的标记, 比跑 `go version` 快也不依赖本机装没装 go
GO_MAGIC = b"\xff Go buildinf:"


def is_go_binary(path):
    """Go 产物整体豁免: Go 用 internal/cpu 做特性检测, 不按编译基线内联 LSE。
    实测纯 Go 的 space-server / upload-server / qmd-tool 和 cgo 版 ime-server-rime
    在 ferrari 上都正常 (2026-10-04 真机验证拼音五笔可用)。
    但 cgo 链进来的 C++ 代码不在此列 —— 那部分符号带 _Z 前缀, 照查不误。"""
    try:
        with open(path, "rb") as f:
            return GO_MAGIC in f.read()
    except OSError:
        return False

SYM_LINE = re.compile(r"^[0-9a-f]+ <(.+?)>:")
INSN_LINE = re.compile(r"^\s+([0-9a-f]+):\s+\S+\s+(\S+)")


def scan(path, objdump="objdump"):
    """返回 (裸露的 [(地址, 指令, 符号)], outline 保护数, Go runtime 数)。"""
    try:
        out = subprocess.run(
            [objdump, "-d", path], capture_output=True, text=True, errors="ignore", check=False
        ).stdout
    except FileNotFoundError:
        print(f"✗ 找不到 {objdump}", file=sys.stderr)
        sys.exit(2)

    is_go = is_go_binary(path)
    sym, window = None, []
    naked, guarded, goruntime = [], 0, 0

    for line in out.splitlines():
        m = SYM_LINE.match(line)
        if m:
            sym, window = m.group(1), []
            continue
        m = INSN_LINE.match(line)
        if not m:
            continue
        addr, mnem = m.group(1), m.group(2).lower()

        if LSE.match(mnem):
            if sym and sym.startswith("__aarch64_"):
                guarded += 1                      # 名字还在的 outline helper
            elif any(x == "cbz" for x in window[-3:]) and any(x == "ldrb" for x in window[-4:]):
                guarded += 1                      # 名字没了, 但前面有 CPU 能力判断
            elif is_go and not (sym or "").startswith("_Z"):
                goruntime += 1                    # Go 自己管, 实测 ferrari 正常
            elif sym and sym.startswith(GO_SYMS):
                goruntime += 1
            else:
                naked.append((addr, mnem, sym or "?"))
        window.append(mnem)

    return naked, guarded, goruntime


def main():
    if len(sys.argv) < 2:
        print("用法: lse_scan.py <二进制> [...]", file=sys.stderr)
        sys.exit(2)

    import os
    objdump = os.environ.get("OBJDUMP", "objdump")
    bad = 0

    for path in sys.argv[1:]:
        naked, guarded, go = scan(path, objdump)
        name = os.path.basename(path)
        if naked:
            bad = 1
            print(f"  ✗ {name:<42} 裸露 {len(naked)} 条 LSE — ferrari (A53) 会 SIGILL")
            for addr, mnem, sym in naked[:3]:
                print(f"      0x{addr}  {mnem:<9} 在 {sym[:48]}")
            if len(naked) > 3:
                print(f"      … 另有 {len(naked) - 3} 条")
        else:
            extra = []
            if guarded:
                extra.append(f"{guarded} 条受 CPU 判断保护")
            if go:
                extra.append(f"{go} 条属 Go runtime")
            note = f"  ({', '.join(extra)})" if extra else ""
            print(f"  ✓ {name:<42} 干净{note}")

    sys.exit(bad)


if __name__ == "__main__":
    main()
