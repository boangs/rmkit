# 由 installer/install.sh 的 --uninstall 段原样提取 (去掉外层 ssh 引号转义); 改动请两边同步
REMOTE_BASE=/home/root/rmkit-cn
    systemctl stop    rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime-http.service 2>/dev/null || true
    systemctl disable rmkit-cn-upload.service rmkit-cn-version.path rmkit-cn-ime-http.service 2>/dev/null || true
    # 历史 Python IME unit (现已归档到 legacy/ime-py/), 老设备上可能残留, 一并清
    systemctl stop    rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    systemctl disable rmkit-cn-ime.service rmkit-cn-ime-udev.service 2>/dev/null || true
    rm -rf $REMOTE_BASE
    # 清 upper (overlay 上层 tmpfs) + lower (ext4) 的 unit / drop-in
    mount -o remount,rw / 2>/dev/null || true
    MNT=/tmp/rmkit-cn-uninst-rootfs
    mkdir -p $MNT && mount --bind / $MNT 2>/dev/null || true
    for D in /etc $MNT/etc; do
      rm -f $D/systemd/system/rmkit-cn-*.service $D/systemd/system/rmkit-cn-*.path
      rm -f $D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf \
            $D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.bak* \
            $D/systemd/system/xochitl.service.d/zz-rmkit-cn.conf.old
      rmdir $D/systemd/system/xochitl.service.d 2>/dev/null || true
    done
    if mountpoint -q $MNT 2>/dev/null; then sync; umount -l $MNT 2>/dev/null || true; rmdir $MNT 2>/dev/null || true; fi
    rm -f /etc/udev/rules.d/99-rmkit-cn-ime.rules
    # 清理 XOVI QMD 文件 (通配: 顶层 *.qmd 全部由 rmkit-cn 投放, 同 precheck.sh 的
    # rm -f $DEPLOY/*.qmd; 逐个列名历史上漏过 glyph_selection_ai / pinyin_interceptor,
    # 残留 qmd 配上新固件 hashtab 会让 qmldiff panic。别的扩展用子目录如 chess/, 不受影响)
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/*.qmd
    rm -f /home/root/xovi/exthome/qt-resource-rebuilder/zh_CN.rcc
    rm -rf /home/root/xovi/exthome/qt-resource-rebuilder/zh_CN
    # 清理 xovi 扩展
    rm -f /home/root/xovi/extensions.d/librarian.so /home/root/xovi/extensions.d/xovi-message-broker.so
    # 清理中文翻译 qm
    mount -o remount,rw / 2>/dev/null || true
    rm -f /usr/share/remarkable/xochitl/translations/reMarkable_zh_CN.qm
    systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null || true
    echo '卸载完成'
