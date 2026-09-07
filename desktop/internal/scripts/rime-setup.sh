# 由 installer/install.sh 的 RIME_EOF 段原样提取 (设备端 bash -s 执行); 改动请两边同步
set -e
STAGE=/home/root/rmkit-cn/rime-stage
SHARED=/home/root/rmkit-cn/rime
USERD=/home/root/.rmkit-rime
PKG="$STAGE/rime-prebuilt.tar.gz"
[ -f "$PKG" ] || { echo "    (无词库包, 跳过)"; exit 0; }
NEWMD5=$(md5sum "$PKG" | cut -d' ' -f1)
OLDMD5=$(cat /home/root/rmkit-cn/.rime_pkg_md5 2>/dev/null || echo "")
if [ "$NEWMD5" = "$OLDMD5" ] && [ -f "$USERD/build/rime_frost.table.bin" ]; then
  echo "    词库未变, 跳过 (保留 userdb 词频)"; exit 0
fi
mkdir -p "$(dirname "$SHARED")" "$USERD"
rm -rf "$SHARED"; tar xzf "$STAGE/rime-runtime-data.tar.gz" -C "$(dirname "$SHARED")"
rm -rf "$USERD/build"; tar xzf "$PKG" -C "$USERD"
[ -f "$USERD/build/rime_frost.table.bin" ] || { echo "    ✗ 词库解包失败"; exit 1; }
mkdir -p "$USERD/rime_frost.userdb" "$USERD/sync" "$USERD/trash"
[ -f "$USERD/installation.yaml" ] || cat > "$USERD/installation.yaml" <<YAML
distribution_code_name: "rmkit-cn"
distribution_name: "rmkit-cn"
distribution_version: 1.0
install_time: "$(date)"
installation_id: "$(cat /proc/sys/kernel/random/uuid)"
rime_version: 1.11.2
YAML
: > "$USERD/user.yaml"
printf 'var:\n  last_build_time: %s\n' "$(date +%s)" > "$USERD/user.yaml"
echo "$NEWMD5" > /home/root/rmkit-cn/.rime_pkg_md5
echo "    ✓ 词库就绪 (拼音 + 五笔86)"
