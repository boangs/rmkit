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
        -e "s#/etc/os-release#$SB/etc/os-release#" \
        -e "s#/tmp/rmkit-no-fuse#$SB/no-fuse-absent#" \
        -e "s#^SYSD=/etc/systemd/system#SYSD=$SB/etc/systemd/system#" \
        -e "s#/home/root/remarkable-space/#$SB/home/root/remarkable-space/#" \
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


echo "=== 场景: 空间后端单元自愈 (系统升级换槽后 /etc 里的单元没了) ==="
setup sp yes FW1
S="$ROOT/sp/etc/systemd/system"; R="$ROOT/sp/home/root/rmkit-cn"
mkdir -p "$S/remarkable-space.service.d" "$S/xochitl.service.d" "$ROOT/sp/home/root/remarkable-space"
echo unit > "$S/remarkable-space.service"; echo api > "$S/remarkable-space.service.d/10-store-api.conf"
echo dropin > "$S/xochitl.service.d/zz-space.conf"
printf '#!/bin/sh\n' > "$ROOT/sp/home/root/remarkable-space/space-server"; chmod +x "$ROOT/sp/home/root/remarkable-space/space-server"
sh "$ROOT/sp/precheck.sh" 2>/dev/null
chk "单元在时存一份到 /home" "10-store-api.conf remarkable-space.service zz-space.conf" "$(sos "$R/etc/space-systemd")"
rm -rf "$S"   # 模拟 OTA 换槽: 新系统的 /etc 里没有空间的单元
: > "$R/.starts"
sh "$ROOT/sp/precheck.sh" 2>/dev/null
chk "后端单元拷回" "unit" "$(cat "$S/remarkable-space.service" 2>/dev/null)"
chk "商店配置拷回" "api" "$(cat "$S/remarkable-space.service.d/10-store-api.conf" 2>/dev/null)"
chk "外壳 drop-in 拷回" "dropin" "$(cat "$S/xochitl.service.d/zz-space.conf" 2>/dev/null)"
chk "开机自启补上" "$S/remarkable-space.service" "$(readlink "$S/multi-user.target.wants/remarkable-space.service")"
chk "仍是 ok" "ok" "$(mode "$R/inject-status.json")"

echo "=== 场景: 空间已卸载 (没有后端程序) 不复活单元 ==="
rm -rf "$S" "$ROOT/sp/home/root/remarkable-space"
: > "$R/.starts"
sh "$ROOT/sp/precheck.sh" 2>/dev/null
chk "不拷回" "no" "$([ -f "$S/remarkable-space.service" ] && echo yes || echo no)"

echo "=== 场景: 熔断时不碰空间单元 ==="
setup sf yes FW1
S="$ROOT/sf/etc/systemd/system"; R="$ROOT/sf/home/root/rmkit-cn"
mkdir -p "$R/etc/space-systemd" "$ROOT/sf/home/root/remarkable-space"
echo unit > "$R/etc/space-systemd/remarkable-space.service"
printf '#!/bin/sh\n' > "$ROOT/sf/home/root/remarkable-space/space-server"; chmod +x "$ROOT/sf/home/root/remarkable-space/space-server"
echo "rescue@x" > "$R/.fuse_tripped"
sh "$ROOT/sf/precheck.sh" 2>/dev/null
chk "紧急修复/熔断后不复活空间" "no" "$([ -f "$S/remarkable-space.service" ] && echo yes || echo no)"

# 假 fw-upgrade: 被拉起就留个记号 (沙盒里没有 systemd-run, precheck 走 nohup 分支)
fake_fwup() { # $1=sandbox名
    printf '#!/bin/sh\n: > "%s/fwup-ran"\n' "$ROOT/$1" > "$ROOT/$1/home/root/rmkit-cn/bin/fw-upgrade.sh"
    chmod +x "$ROOT/$1/home/root/rmkit-cn/bin/fw-upgrade.sh"
}
wait_mark() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$1" ] && break; sleep 0.2; done; [ -f "$1" ] && echo yes || echo no; }

echo "=== 场景: 构建时间不变、版本号变了 (3.29.0.152 → .153) ==="
setup sv yes FW1-3.29.0.152
R="$ROOT/sv/home/root/rmkit-cn"; D="$ROOT/sv/home/root/xovi/exthome/qt-resource-rebuilder"
echo 'IMG_VERSION="3.29.0.153"' > "$ROOT/sv/etc/os-release"
echo FW1-3.29.0.152 > "$R/.last_fw_version"
fake_fwup sv
sh "$ROOT/sv/precheck.sh" 2>/dev/null
chk "认出升级 → 拉起 fw-upgrade" "yes" "$(wait_mark "$ROOT/sv/fwup-ran")"
chk "旧 hashtab 不放行 qmldiff (降级)" "degraded" "$(mode "$R/inject-status.json")"
chk "不往部署目录放 qmd" "" "$(qmds "$D")"

echo "=== 场景: 老设备标记是纯构建时间 → 当成换了固件重编一次 ==="
setup sl yes FW1
R="$ROOT/sl/home/root/rmkit-cn"
echo 'IMG_VERSION=3.29.0.153' > "$ROOT/sl/etc/os-release"
fake_fwup sl
sh "$ROOT/sl/precheck.sh" 2>/dev/null
chk "拉起 fw-upgrade" "yes" "$(wait_mark "$ROOT/sl/fwup-ran")"

echo "=== 场景: 新固件上崩出熔断后, 重启仍要拉起 fw-upgrade ==="
setup sc yes FW1-3.29.0.152
R="$ROOT/sc/home/root/rmkit-cn"
echo 'IMG_VERSION="3.29.0.153"' > "$ROOT/sc/etc/os-release"
echo FW1-3.29.0.152 > "$R/.last_fw_version"
echo "crashloop@1 fw=FW1" > "$R/.fuse_tripped"
fake_fwup sc
sh "$ROOT/sc/precheck.sh" 2>/dev/null
chk "熔断照样全摘" "disabled" "$(mode "$R/inject-status.json")"
chk "但 fw-upgrade 被拉起 (它成功后会清熔断)" "yes" "$(wait_mark "$ROOT/sc/fwup-ran")"

echo "=== 场景: 紧急修复的熔断不被系统升级解开 ==="
setup sr yes FW1-3.29.0.152
R="$ROOT/sr/home/root/rmkit-cn"
echo 'IMG_VERSION="3.29.0.153"' > "$ROOT/sr/etc/os-release"
echo FW1-3.29.0.152 > "$R/.last_fw_version"
echo "rescue@1" > "$R/.fuse_tripped"
fake_fwup sr
sh "$ROOT/sr/precheck.sh" 2>/dev/null
chk "不拉起 fw-upgrade" "no" "$(wait_mark "$ROOT/sr/fwup-ran")"
echo
echo "通过 $PASS, 失败 $FAIL"
[ "$FAIL" -eq 0 ]
