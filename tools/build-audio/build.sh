#!/bin/bash
# 在 lima rmbuild 里交叉编译 reMarkable (chiappa, 3.27 SDK) 的蓝牙音频链:
#   alsa-lib → sbc → bluez(bluetoothd+libbluetooth) → bluez-alsa → mpg123
# 产物 prefix=/home/root/.local/opt/rmkit-audio, 通过 DESTDIR 装进 SDK sysroot 同路径 (让 pkg-config
# 的 sysroot 前缀机制自然生效), 最后从 sysroot 里把该前缀打包。
set -euo pipefail
SRC=${SRC:-$HOME/bt-audio-src}   # 上游源码包: alsa-lib-1.2.12 sbc-2.0 bluez-5.79 bluez-alsa-4.3.1 mpg123-1.32.9
OUT=${OUT:-$HOME/bt-audio-out}   # 产物 rmkit-audio.tar.gz → 仓库 vendor/audio/rmkit-audio-aarch64.tar.gz
B=$HOME/bt-audio-build
PREFIX=/home/root/.local/opt/rmkit-audio
source /opt/codex/chiappa/3.27.0.97/environment-setup-cortexa55-remarkable-linux
SYSROOT=$SDKTARGETSYSROOT
HOST=aarch64-remarkable-linux
export LDFLAGS="$LDFLAGS -Wl,-rpath,$PREFIX/lib -L$SYSROOT$PREFIX/lib"
export CPPFLAGS="${CPPFLAGS:-} -I$SYSROOT$PREFIX/include"
export CFLAGS="$CFLAGS -I$SYSROOT$PREFIX/include"
export PKG_CONFIG_LIBDIR="$SYSROOT$PREFIX/lib/pkgconfig:$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
mkdir -p $B $OUT
sudo mkdir -p $SYSROOT$PREFIX/include $SYSROOT$PREFIX/lib/pkgconfig && sudo chmod -R a+rX $SYSROOT/home
log() { echo "===== $*"; }

log "1/5 alsa-lib"
if [ -f $SYSROOT$PREFIX/lib/libasound.so.2 ]; then echo "已装, 跳过"; else
cd $B && rm -rf alsa-lib-1.2.12 && tar xf $SRC/alsa-lib-1.2.12.tar.bz2 && cd alsa-lib-1.2.12
./configure --host=$HOST --prefix=$PREFIX --disable-python --disable-old-symbols --disable-topology --with-configdir=$PREFIX/share/alsa --with-plugindir=$PREFIX/lib/alsa-lib >configure.log 2>&1
make -j8 >make.log 2>&1 && sudo -E env PATH="$PATH" make install DESTDIR=$SYSROOT >install.log 2>&1
ls $SYSROOT$PREFIX/lib/libasound.so.2 >/dev/null
fi

log "2/5 sbc"
if [ -f $SYSROOT$PREFIX/lib/libsbc.so.1 ]; then echo "已装, 跳过"; else
cd $B && rm -rf sbc-2.0 && tar xf $SRC/sbc-2.0.tar.xz && cd sbc-2.0
./configure --host=$HOST --prefix=$PREFIX --disable-tools --disable-tester >configure.log 2>&1
make -j8 >make.log 2>&1 && sudo -E env PATH="$PATH" make install DESTDIR=$SYSROOT >install.log 2>&1
fi

log "3/5 bluez (bluetoothd + libbluetooth)"
if [ -f $SYSROOT$PREFIX/libexec/bluetooth/bluetoothd ]; then echo "已装, 跳过"; else
cd $B && rm -rf bluez-5.79 && tar xf $SRC/bluez-5.79.tar.xz && cd bluez-5.79
./configure --host=$HOST --prefix=$PREFIX --sysconfdir=$PREFIX/etc --localstatedir=/var \
  --enable-library --disable-udev --disable-cups --disable-obex --disable-systemd --disable-manpages \
  --disable-client --disable-monitor --disable-mesh --disable-midi --disable-hid2hci --disable-datafiles \
  --disable-tools --disable-testing --disable-experimental --enable-a2dp --enable-avrcp --enable-network=no \
  --with-dbusconfdir=$PREFIX/etc/dbus-1 --with-dbussystembusdir=$PREFIX/share/dbus-1/system-services >configure.log 2>&1
make -j8 >make.log 2>&1 && sudo -E env PATH="$PATH" make install DESTDIR=$SYSROOT >install.log 2>&1
ls $SYSROOT$PREFIX/libexec/bluetooth/bluetoothd >/dev/null
fi

log "4/5 bluez-alsa"
cd $B && rm -rf bluez-alsa-4.3.1 && tar xf $SRC/bluez-alsa-4.3.1.tar.gz && cd bluez-alsa-4.3.1
autoreconf -fi >autoreconf.log 2>&1
./configure --host=$HOST --prefix=$PREFIX --enable-systemd=no --disable-manpages \
  --with-alsaplugindir=$PREFIX/lib/alsa-lib --with-alsaconfdir=$PREFIX/share/alsa/alsa.conf.d \
  --with-dbusconfdir=$PREFIX/etc/dbus-1/system.d >configure.log 2>&1
make -j8 >make.log 2>&1 && sudo -E env PATH="$PATH" make install DESTDIR=$SYSROOT >install.log 2>&1
ls $SYSROOT$PREFIX/bin/bluealsa >/dev/null

log "5/5 mpg123"
cd $B && rm -rf mpg123-1.32.9 && tar xf $SRC/mpg123-1.32.9.tar.bz2 && cd mpg123-1.32.9
./configure --host=$HOST --prefix=$PREFIX --with-audio=alsa --with-default-audio=alsa --disable-modules --with-cpu=aarch64 >configure.log 2>&1
make -j8 >make.log 2>&1 && sudo -E env PATH="$PATH" make install DESTDIR=$SYSROOT >install.log 2>&1
ls $SYSROOT$PREFIX/bin/mpg123 >/dev/null

log "修 alsa 配置: 上游 alsa.conf 只从 /etc/alsa/conf.d 等绝对路径加载 conf.d, bluealsa 的 pcm 定义装在前缀下加载不到 (Unknown PCM bluealsa)"
sudo mkdir -p $SYSROOT$PREFIX/etc/alsa/conf.d
sudo cp $SYSROOT$PREFIX/share/alsa/alsa.conf.d/20-bluealsa.conf $SYSROOT$PREFIX/etc/alsa/conf.d/
grep -q "$PREFIX/etc/alsa/conf.d" $SYSROOT$PREFIX/share/alsa/alsa.conf || \
  sudo sed -i "s|^\t\t\t\"/etc/alsa/conf.d\"|\t\t\t\"/etc/alsa/conf.d\"\n\t\t\t\"$PREFIX/etc/alsa/conf.d\"|" $SYSROOT$PREFIX/share/alsa/alsa.conf
# 瘦身: 头文件/man/静态库/libtool 文件设备上用不到
sudo rm -rf $SYSROOT$PREFIX/share/man $SYSROOT$PREFIX/include $SYSROOT$PREFIX/lib/pkgconfig $SYSROOT$PREFIX/lib/*.la $SYSROOT$PREFIX/lib/alsa-lib/*.a $SYSROOT$PREFIX/lib/alsa-lib/*.la

log "打包"
# 包根即前缀内容 (bin/ lib/ share/ etc/), 设备端 audio-setup 直接解到 $PREFIX
cd $SYSROOT$PREFIX && sudo tar -czf $OUT/rmkit-audio.tar.gz --owner=0 --group=0 .
sudo chown $(id -u) $OUT/rmkit-audio.tar.gz; ls -la $OUT/rmkit-audio.tar.gz
log "DONE"
