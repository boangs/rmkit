#!/usr/bin/env bash
# 发布前体检: 扫 dist/ 里要进 xochitl 进程的二进制, 看有没有 A53 不认的 LSE 原子指令。
#
# 为什么需要这道闸:
#   dist/ 被 gitignore, 不进仓库。源码里的基线修复 (-mcpu=cortex-a53+crypto) 和
#   发布包里的二进制是两回事 —— v1.2.1 就是这么漏的: Makefile 和编译期自检都对,
#   但打包用的是修复之前编的 qml_inject_impl-aarch64.so (147 条内联 LSE),
#   装到 Paper Pro (ferrari, Cortex-A53) 上 xochitl 直接 SIGILL 进 crash loop。
#   见 boangs/rmkit#7。
#
# 两台 aarch64 不是一回事:
#   chiappa (Paper Pro Move) = Cortex-A55, ARMv8.2, 有 LSE
#   ferrari (Paper Pro)      = Cortex-A53, ARMv8.0, 没有 LSE → 执行即 SIGILL
#
# 用法:  scripts/check-dist.sh [dist 目录]       默认 dist/
# 退出码: 0 = 干净可发布, 1 = 有问题别发

set -uo pipefail
DIST="${1:-dist}"

# ARMv8.1 的 LSE 原子指令全集。GCC 的 outline atomics helper (__aarch64_*) 会在
# 运行时探测 CPU 再选路径, 那是安全的, 扫描时跳过。
LSE_RE='^(cas|casa|casab|casah|casal|casalb|casalh|casb|cash|casl|caslb|caslh|casp|caspa|caspal|caspl|swp|swpa|swpab|swpah|swpal|swpalb|swpalh|swpb|swph|swpl|swplb|swplh|ldadd|ldadda|ldaddab|ldaddah|ldaddal|ldaddalb|ldaddalh|ldaddb|ldaddh|ldaddl|ldaddlb|ldaddlh|ldclr|ldclra|ldclral|ldclrb|ldclrh|ldclrl|ldeor|ldeora|ldeoral|ldeorb|ldeorh|ldeorl|ldset|ldseta|ldsetal|ldsetb|ldseth|ldsetl|ldsmax|ldsmaxa|ldsmaxal|ldsmaxl|ldsmin|ldsmina|ldsminal|ldsminl|ldumax|ldumaxa|ldumaxal|ldumaxl|ldumin|ldumina|lduminal|lduminl|stadd|staddl|stclr|stclrl|steor|steorl|stset|stsetl|stsmax|stsmaxl|stumax|stumaxl)$'

# 这些会被 LD_PRELOAD 或 dlopen 进 xochitl 进程 —— 它们带 LSE 就直接崩主程序。
# 独立进程 (upload-server / ime-server / qmd-tool 等) 不在此列: 那些是 Go 编的,
# Go 自己管指令集, 而且崩了也只崩自己。
IN_XOCHITL='qml_inject-aarch64\.so|qml_inject_impl-aarch64\.so|ime_hook\.so|librarian-aarch64\.so|xovi-message-broker-aarch64\.so|xovi\.so'

OBJDUMP="${OBJDUMP:-objdump}"
command -v "$OBJDUMP" >/dev/null 2>&1 || { echo "✗ 找不到 objdump (可设 OBJDUMP=...)" >&2; exit 1; }

[ -d "$DIST" ] || { echo "✗ 没有目录 $DIST" >&2; exit 1; }

echo "扫描 $DIST — 查 A53 不认的 LSE 原子指令"
echo

fail=0
warn=0
checked=0
while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q "ARM aarch64" || continue

    base=$(basename "$f")
    # 反汇编, 按所属符号分类数 LSE:
    #   __aarch64_*  GCC 的 outline atomics helper, 运行时探测 CPU, 安全 —— 跳过
    #   _Z*          C++ mangled, 由 CFLAGS 的基线决定, 带 LSE 就是真问题
    #   其余         Go 自己的代码 (runtime/sync/...), Go 有 internal/cpu 探测, 不拦
    # 纯 Go 二进制整体会扫出几百条, 那些都在 Go 符号里; cgo 链进来的 C++ 库才危险。
    counts=$("$OBJDUMP" -d "$f" 2>/dev/null | awk -v re="$LSE_RE" '
        /^[0-9a-f]+ </ { fn = $2; gsub(/[<>:]/, "", fn); skip = (fn ~ /^__aarch64_/) }
        !skip && $1 ~ /:$/ && NF >= 3 && tolower($3) ~ re {
            if (fn ~ /^_Z/) cpp++; else other++
        }
        END { printf "%d %d", cpp + 0, other + 0 }
    ')
    n=${counts%% *}          # C++ 符号里的 —— 这个才算数
    n_go=${counts##* }       # 其余 (多半是 Go runtime)

    checked=$((checked + 1))
    if [ "$n" -gt 0 ]; then
        if echo "$base" | grep -qE "$IN_XOCHITL"; then
            printf '  ✗ %-40s C++ 符号里 %4s 条 LSE — 进 xochitl 进程, ferrari 会 SIGILL\n' "$base" "$n"
            fail=1
        else
            # 独立进程: 崩了只崩自己, 不拦发布, 但得说出来 —— 比如 ime-server-rime
            # 里 opencc 的那几条, 真走到那个函数输入法就没了。
            printf '  ! %-40s C++ 符号里 %4s 条 LSE — 独立进程, 不拦, 但在 ferrari 上会崩\n' "$base" "$n"
            warn=1
        fi
    elif [ "$n_go" -gt 0 ]; then
        printf '  ✓ %-40s 干净 (另有 %s 条在 Go 符号里, Go 自带 CPU 探测)\n' "$base" "$n_go"
    else
        printf '  ✓ %-40s 干净\n' "$base"
    fi
done < <(find "$DIST" -type f \( -name '*.so' -o -perm -u+x \) 2>/dev/null | sort)

echo
if [ "$checked" -eq 0 ]; then
    echo "✗ $DIST 里一个 aarch64 二进制都没有 — 路径对吗?" >&2
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'
✗ 别发。上面打 ✗ 的库会被加载进 xochitl 进程, 在 Paper Pro (Cortex-A53) 上
  执行到 LSE 指令就是 SIGILL, 表现为装完 xochitl crash loop 然后回退出厂。

  修法: 去编译机重编, Makefile 里的 ARCH_BASELINE 已经是 -mcpu=cortex-a53+crypto,
        编译期自检会拦住。注意必须覆盖 -mcpu 而不是加 -march —— 两者同时给出时
        GCC 只用 -mcpu, -march 不生效。

        scp -r intercept/qml-inject boangs@<编译机>:/tmp/
        ssh  boangs@<编译机> 'cd /tmp/qml-inject && make'
        scp  'boangs@<编译机>:/tmp/qml-inject/qml_inject*-aarch64.so' dist/
EOF
    exit 1
fi

if [ "$warn" -ne 0 ]; then
    echo "✓ $checked 个 aarch64 二进制, 进 xochitl 的那些干净 — 可以发布"
    echo "  但上面打 ! 的在 ferrari 上会崩自己 (不影响 xochitl), 建议一并重编。"
else
    echo "✓ $checked 个 aarch64 二进制, 进 xochitl 的那些都没有内联 LSE — 可以发布"
fi
