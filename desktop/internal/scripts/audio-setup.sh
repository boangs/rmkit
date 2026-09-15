# 由 installer/install.sh 的 AUDIO_EOF 段原样提取 (设备端 bash -s 执行); 改动请两边同步
# 蓝牙音频组件 (alsa-lib + bluez + bluez-alsa + mpg123, 交叉编译产物, 见 tools/build-audio/):
# 解包到 /home/root/.local/opt/rmkit-audio, 不碰 / 与 /etc 下层。D-Bus 策略文件 (bluealsa 要独占
# org.bluealsa 名字) 由 upload-server 在首次启动 bluealsa 时写进 /etc (tmpfs 上层) 并让 dbus 重载,
# 重启后丢了也会自动补, 所以不需要双写 ext4 下层。
set -e
STAGE=/home/root/rmkit-cn/audio-stage
PREFIX=/home/root/.local/opt/rmkit-audio
PKG="$STAGE/rmkit-audio.tar.gz"
[ -f "$PKG" ] || { echo "    (无蓝牙音频包, 跳过)"; exit 0; }
NEWMD5=$(md5sum "$PKG" | cut -d' ' -f1)
OLDMD5=$(cat /home/root/rmkit-cn/.audio_pkg_md5 2>/dev/null || echo "")
if [ "$NEWMD5" = "$OLDMD5" ] && [ -x "$PREFIX/bin/bluealsa" ]; then
  echo "    蓝牙音频组件未变, 跳过"; exit 0
fi
mkdir -p "$(dirname "$PREFIX")"
rm -rf "$PREFIX.new"; mkdir -p "$PREFIX.new"
tar xzf "$PKG" -C "$PREFIX.new" --no-same-owner --no-same-permissions   # 包根即前缀内容 (bin/ lib/ share/ etc/)
[ -x "$PREFIX.new/bin/bluealsa" ] && [ -x "$PREFIX.new/bin/mpg123" ] || { echo "    ✗ 蓝牙音频包解包失败"; rm -rf "$PREFIX.new"; exit 1; }
# 解包成功才停旧进程换目录 (bluealsa 一停耳机的 A2DP 链路就断, 失败时不能白白打断播放)
killall -q mpg123 2>/dev/null || true
killall -q bluealsa 2>/dev/null || true
rm -rf "$PREFIX"; mv "$PREFIX.new" "$PREFIX"
echo "$NEWMD5" > /home/root/rmkit-cn/.audio_pkg_md5
echo "    ✓ 蓝牙音频组件已部署 ($PREFIX)"
