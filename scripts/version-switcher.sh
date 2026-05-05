#!/usr/bin/env bash
# scripts/version-switcher.sh
# 固件版本变化时: 清旧 qmd → 等新 hashtab → 重编 → restart xochitl
set -euo pipefail

RMKIT_DIR="${RMKIT_DIR:-/home/root/rmkit-cn}"
XOVI_DIR="${XOVI_DIR:-/home/root/xovi}"
VERSION_FILE="${VERSION_FILE:-/etc/version}"
QMD_SRC_DIR="$RMKIT_DIR/qmd-src"
QMD_DEPLOY_DIR="$XOVI_DIR/exthome/qt-resource-rebuilder"
QMD_TOOL="$RMKIT_DIR/bin/qmd-tool"
HASHTAB="$XOVI_DIR/exthome/qt-resource-rebuilder/hashtab"

if [ ! -f "$VERSION_FILE" ]; then
  echo "错误：找不到版本文件 $VERSION_FILE" >&2
  exit 1
fi

FW_VERSION=$(cat "$VERSION_FILE" | head -n 1)
echo "[version-switcher] 固件版本: $FW_VERSION"

# ─── 步骤 1: 清掉旧 qmd (防止孤儿 hash 导致 xochitl crash)
echo "[version-switcher] 清除旧 qmd..."
for f in "$QMD_DEPLOY_DIR"/*.qmd; do
  [ -f "$f" ] && mv "$f" "$f.upgrading" && echo "  暂移: $(basename $f)"
done

# ─── 步骤 2: 等新 hashtab 生成 (qt-resource-rebuilder 需要 xochitl 跑一次)
echo "[version-switcher] 等待新 hashtab 生成 (最多 3 分钟)..."
OLD_HASHTAB_MD5="${RMKIT_LAST_HASHTAB_MD5:-}"
for i in $(seq 1 36); do
  if [ -f "$HASHTAB" ]; then
    NEW_MD5=$(md5sum "$HASHTAB" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$NEW_MD5" ] && [ "$NEW_MD5" != "$OLD_HASHTAB_MD5" ]; then
      echo "[version-switcher] hashtab 已更新 (md5=$NEW_MD5)"
      break
    fi
  fi
  sleep 5
done

if [ ! -f "$HASHTAB" ]; then
  echo "[version-switcher] 警告: hashtab 未生成，跳过重编"
  # 恢复旧 qmd 以维持基本功能
  for f in "$QMD_DEPLOY_DIR"/*.qmd.upgrading; do
    [ -f "$f" ] && mv "$f" "${f%.upgrading}"
  done
  exit 0
fi

# ─── 步骤 3: 用 qmd-tool 重编 qmd-src/*.qmd
if [ ! -x "$QMD_TOOL" ]; then
  echo "[version-switcher] 错误: $QMD_TOOL 不存在" >&2
  exit 1
fi

if [ ! -d "$QMD_SRC_DIR" ]; then
  echo "[version-switcher] 错误: $QMD_SRC_DIR 不存在" >&2
  exit 1
fi

echo "[version-switcher] 重编 qmd..."
RECOMPILE_OK=true
for src in "$QMD_SRC_DIR"/*.qmd; do
  [ -f "$src" ] || continue
  base=$(basename "$src")
  if "$QMD_TOOL" hash -hashtab "$HASHTAB" "$src" > "$QMD_DEPLOY_DIR/$base.tmp" 2>/dev/null; then
    mv "$QMD_DEPLOY_DIR/$base.tmp" "$QMD_DEPLOY_DIR/$base"
    echo "  ✓ $base"
  else
    rm -f "$QMD_DEPLOY_DIR/$base.tmp"
    echo "  ✗ $base 编译失败" >&2
    RECOMPILE_OK=false
  fi
done

# 清掉 .upgrading 备份
rm -f "$QMD_DEPLOY_DIR"/*.qmd.upgrading

if [ "$RECOMPILE_OK" = "true" ]; then
  echo "[version-switcher] 重编完成，重启 xochitl..."
  systemctl restart xochitl.service
  echo "[version-switcher] ✓ 完成"
else
  echo "[version-switcher] 部分编译失败，请检查" >&2
  exit 1
fi
