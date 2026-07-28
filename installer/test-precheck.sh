#!/bin/bash
# precheck.sh fail-open 逻辑沙盒测试 —— 纯本地, 不碰真机。
#
#   bash installer/test-precheck.sh
#
# 为什么值得有: precheck.sh 是 6 次砖机复盘后的唯一防线, 但它只在设备启动时跑,
# 想验证"OTA 后会不会连坐摘掉运行时注入""熔断时是否真的全摘"只能等真实事故。
# 这里把它的绝对路径前缀 sed 重写到临时 sandbox, 造出各种设备状态直接断言结果。
# 改 precheck.sh 的任何判据/摘除策略后请先跑这个, 再考虑上真机。
set -u

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/precheck.sh}"
ROOT=$(mktemp -d -t precheck-sandbox.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

# 造 sandbox: 把 /home/root/... 重写到 $SB/home/root/...
setup() { # $1=sandbox名 $2=有无qml_inject产物(yes/no) $3=hashtab固件版本 $4=装共享lib(yes/no,默认yes)
    SB="$ROOT/$1"
    rm -rf "$SB"
    mkdir -p "$SB/home/root/rmkit-cn/bin" \
             "$SB/home/root/rmkit-cn/active" \
             "$SB/home/root/rmkit-cn/quarantine" \
             "$SB/home/root/rmkit-cn/compiled-qmd/FW1" \
             "$SB/home/root/xovi/exthome/qt-resource-rebuilder" \
             "$SB/home/root/xovi/extensions.d" \
             "$SB/etc"
    D="$SB/home/root/xovi/exthome/qt-resource-rebuilder"
    R="$SB/home/root/rmkit-cn"
    echo FW1 > "$SB/etc/version"
    echo FW1 > "$R/.last_fw_version"          # 与 FW 相同 → 不触发 fw-upgrade
    : > "$SB/home/root/xovi/xovi.so"
    : > "$R/bin/ime_hook.so"
    printf 'x' > "$D/hashtab"; for i in $(seq 200); do printf 'x' >> "$D/hashtab"; done
    echo "$3" > "$D/hashtab.fw_version"
    # cache 里放全套 qmd (含已迁移的 4 个 + pinyin)
    for q in advanced_panel ai_text_button glyph_selection_ai language_zh_cn pinyin_interceptor; do
        echo "qmd-$q" > "$R/compiled-qmd/FW1/$q.qmd"
    done
    # qmd-tool: 假的, 一律 verify 成功
    printf '#!/bin/sh\nexit 0\n' > "$R/bin/qmd-tool"; chmod +x "$R/bin/qmd-tool"
    if [ "$2" = yes ]; then
        : > "$R/bin/qml_inject.so"; : > "$R/bin/qml_inject_impl.so"
        : > "$R/bin/adv_panel.qml"; : > "$R/bin/pinyin_ime.qml"
    fi
    # 共享判据 lib: 默认装 (真实部署形态); 传 no 则不装, 走 precheck 内联 fallback
    if [ "${4:-yes}" = yes ]; then
        sed "s#^RMKIT_LIB_BASE=.*#RMKIT_LIB_BASE=\${RMKIT_LIB_BASE:-$SB/home/root/rmkit-cn}#" \
            "$(dirname "$SRC")/qml-inject-lib.sh" > "$R/bin/qml-inject-lib.sh"
    fi
    # 重写路径前缀后的 precheck
    sed -e "s#^RMKIT=/home/root/rmkit-cn#RMKIT=$SB/home/root/rmkit-cn#" \
        -e "s#^XOVI=/home/root/xovi#XOVI=$SB/home/root/xovi#" \
        -e "s#/etc/version#$SB/etc/version#" \
        -e "s#/tmp/rmkit-no-fuse#$SB/no-fuse-absent#" \
        "$SRC" > "$SB/precheck.sh"
}

chk() { # $1=描述 $2=expected $3=actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); printf '    ✓ %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '    ✗ %s\n      期望: %s\n      实际: %s\n' "$1" "$2" "$3"
    fi
}

qmds() { ls "$1" 2>/dev/null | grep '\.qmd$' | sort | tr '\n' ' ' | sed 's/ $//'; }
sos()  { ls "$1" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
mode() { sed 's/.*"mode":"\([^"]*\)".*/\1/' "$1" 2>/dev/null; }

echo "=== 场景 1: 全健康 + 有 qml_inject 产物 (RMPP) ==="
setup s1 yes FW1
sh "$ROOT/s1/precheck.sh" 2>/dev/null
R="$ROOT/s1/home/root/rmkit-cn"; D="$ROOT/s1/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=ok" "ok" "$(mode "$R/inject-status.json")"
chk "已迁移 qmd 全部摘除 (含 pinyin, 5/5 迁移完)" "" "$(qmds "$D")"
chk "三个 .so 全挂" "ime_hook.so qml_inject.so xovi.so" "$(sos "$R/active")"
chk "无 qmd 被隔离" "" "$(sos "$R/quarantine")"

echo "=== 场景 2: hashtab 不匹配 (OTA 窗口期) + 有产物 ==="
setup s2 yes FW_OLD
sh "$ROOT/s2/precheck.sh" 2>/dev/null
R="$ROOT/s2/home/root/rmkit-cn"; D="$ROOT/s2/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=degraded (不是 disabled)" "degraded" "$(mode "$R/inject-status.json")"
chk "qmd 全摘" "" "$(qmds "$D")"
chk "保留 qml_inject + ime_hook (hook 不依赖 hashtab, 候选框已迁运行时)" \
    "ime_hook.so qml_inject.so" "$(sos "$R/active")"

echo "=== 场景 3: hashtab 不匹配 + 无产物 (rm2/armv7) ==="
setup s3 no FW_OLD
sh "$ROOT/s3/precheck.sh" 2>/dev/null
R="$ROOT/s3/home/root/rmkit-cn"; D="$ROOT/s3/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=disabled (回落旧行为)" "disabled" "$(mode "$R/inject-status.json")"
chk "qmd 全摘" "" "$(qmds "$D")"
chk "无 .so 挂载" "" "$(sos "$R/active")"

echo "=== 场景 4: 全健康 + 无产物 (rm2 正常态) ==="
setup s4 no FW1
sh "$ROOT/s4/precheck.sh" 2>/dev/null
R="$ROOT/s4/home/root/rmkit-cn"; D="$ROOT/s4/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=ok" "ok" "$(mode "$R/inject-status.json")"
chk "全部 5 个 qmd 保留 (含已迁移的, 走 qmd 路径)" \
    "advanced_panel.qmd ai_text_button.qmd glyph_selection_ai.qmd language_zh_cn.qmd pinyin_interceptor.qmd" \
    "$(qmds "$D")"
chk "只挂 xovi + ime_hook" "ime_hook.so xovi.so" "$(sos "$R/active")"

echo "=== 场景 5: 熔断 (.fuse_tripped) + 有产物 → 必须一视同仁全摘 ==="
setup s5 yes FW1
echo "crashloop@x" > "$ROOT/s5/home/root/rmkit-cn/.fuse_tripped"
sh "$ROOT/s5/precheck.sh" 2>/dev/null
R="$ROOT/s5/home/root/rmkit-cn"; D="$ROOT/s5/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=disabled" "disabled" "$(mode "$R/inject-status.json")"
chk "qml_inject 也被摘 (崩因可能是它自己)" "" "$(sos "$R/active")"
chk "qmd 全摘" "" "$(qmds "$D")"

echo "=== 场景 6: 共享 lib 缺失 (老版本升上来) → 内联 fallback 必须等效 ==="
setup s6 yes FW1 no
sh "$ROOT/s6/precheck.sh" 2>/dev/null
R="$ROOT/s6/home/root/rmkit-cn"; D="$ROOT/s6/home/root/xovi/exthome/qt-resource-rebuilder"
chk "mode=ok (lib 缺失不致命)" "ok" "$(mode "$R/inject-status.json")"
chk "fallback 同样摘掉已迁移 qmd (5/5)" "" "$(qmds "$D")"
chk "fallback 同样挂上 qml_inject" "ime_hook.so qml_inject.so xovi.so" "$(sos "$R/active")"

echo
echo "通过 $PASS, 失败 $FAIL"
[ "$FAIL" -eq 0 ]
