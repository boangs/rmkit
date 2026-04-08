#!/usr/bin/env bash
# scripts/version-switcher.sh
# 检测固件版本，切换 QMD 符号链接并重建 hashtable
set -euo pipefail

RMKIT_DIR="${RMKIT_DIR:-/home/root/rmkit-cn}"
XOVI_DIR="${XOVI_DIR:-/home/root/xovi}"
VERSION_FILE="${VERSION_FILE:-/etc/remarkable/version}"
QMD_DIR="$RMKIT_DIR/qmd"

# 读取固件版本（取前两段，如 3.17.1.2 → 3.17）
if [ ! -f "$VERSION_FILE" ]; then
  echo "错误：找不到版本文件 $VERSION_FILE" >&2
  exit 1
fi

# 跨平台版本提取（取前两段数字，如 3.17.1.2 → 3.17）
FW_VERSION=$(head -1 "$VERSION_FILE" | grep -oE '^[0-9]+\.[0-9]+')
echo "当前固件版本：$FW_VERSION"

# 寻找对应的 QMD 目录
if [ -d "$QMD_DIR/$FW_VERSION" ]; then
  TARGET="$FW_VERSION"
  echo "找到精确匹配：$TARGET"
else
  # 降级到最近可用版本
  TARGET=$(ls "$QMD_DIR" | grep -v current | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -1)
  if [ -z "$TARGET" ]; then
    echo "错误：没有任何可用的 QMD 版本目录" >&2
    exit 1
  fi
  echo "警告：固件 $FW_VERSION 暂无对应 QMD，降级使用 $TARGET"
fi

# 切换符号链接
ln -sfn "$QMD_DIR/$TARGET" "$QMD_DIR/current"
echo "已切换到：$QMD_DIR/current -> $TARGET"

# 重建 hashtable（如果 XOVI 已安装）
HASHTABLE_SCRIPT="$XOVI_DIR/rebuild_hashtable"
if [ -x "$HASHTABLE_SCRIPT" ]; then
  echo "重建 hashtable..."
  "$HASHTABLE_SCRIPT"
  echo "hashtable 重建完成"
else
  echo "注意：$HASHTABLE_SCRIPT 不存在，跳过重建（XOVI 未安装）"
fi
