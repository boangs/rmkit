#!/bin/bash
# rmkit-cn OTA 后一键恢复脚本
# 支持 rm2 (armv7l) 和 RMPP/RMPPM (aarch64)
# OTA 升级后运行一次即可恢复所有功能
RMKIT_DIR=/home/root/rmkit-cn
XOVI_DIR=/home/root/xovi

echo "[reenable] 开始恢复 rmkit-cn..."
ARCH=$(uname -m)
echo "[reenable] 架构: $ARCH"

# ─── zz-rmkit-cn.conf 内容 (按架构区分 After=home.mount) ────────
[ "$ARCH" = "aarch64" ] && UNIT_HEADER="[Unit]
After=home.mount

" || UNIT_HEADER=""

ZZ_CONF="${UNIT_HEADER}[Service]
ExecStartPre=/bin/sh -c 'FW=\$(cat /etc/version 2>/dev/null); CACHE=$RMKIT_DIR/compiled-qmd/\$FW; DEPLOY=$XOVI_DIR/exthome/qt-resource-rebuilder; rm -f \"\$DEPLOY\"/*.qmd; [ -d \"\$CACHE\" ] && ls \"\$CACHE\"/*.qmd >/dev/null 2>&1 && cp \"\$CACHE\"/*.qmd \"\$DEPLOY/\"; LAST=\$(cat $RMKIT_DIR/.last_fw_version 2>/dev/null); if [ \"\$FW\" != \"\$LAST\" ]; then nohup bash $RMKIT_DIR/bin/fw-upgrade.sh >/tmp/fw-upgrade.log 2>&1 & fi; exit 0'
WatchdogSec=0
Environment=\"QML_DISABLE_DISK_CACHE=1\"
Environment=\"QML_XHR_ALLOW_FILE_WRITE=1\"
Environment=\"QML_XHR_ALLOW_FILE_READ=1\"
Environment=\"LD_PRELOAD=$XOVI_DIR/xovi.so:$RMKIT_DIR/bin/ime_hook.so\"
Environment=\"QT_RESOURCE_REBUILDER_PATH=$XOVI_DIR/exthome/qt-resource-rebuilder/zh_CN.rcc\""

UPLOAD_SVC="[Unit]
Description=rmkit-cn 文件上传服务
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$RMKIT_DIR/upload-server
ExecStart=$RMKIT_DIR/upload-server/upload-server -listen 0.0.0.0:8080 -static $RMKIT_DIR/upload-server/static -fonts /home/root/.local/share/rmkit-cn/fonts -screens /home/root/.local/share/rmkit-cn/screens -staging /tmp/rmkit_upload -fonts-active /home/root/.local/share/fonts -xochitl-conf /home/root/.config/remarkable/xochitl.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target"

IME_SVC="[Unit]
Description=rmkit-cn 拼音输入法 HTTP 服务
After=multi-user.target

[Service]
Type=simple
User=root
ExecStart=$RMKIT_DIR/bin/ime-server
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target"

VERSION_SVC="[Unit]
Description=rmkit-cn 固件版本切换
After=xochitl.service

[Service]
Type=oneshot
User=root
ExecStart=$RMKIT_DIR/bin/fw-upgrade.sh"

VERSION_PATH="[Unit]
Description=监听 reMarkable 固件版本变化

[Path]
PathChanged=/etc/version

[Install]
WantedBy=multi-user.target"

# ─── 写入配置文件 (按架构选择方式) ──────────────────────────────
mount -o remount,rw / 2>/dev/null || true

if [ "$ARCH" = "aarch64" ]; then
    # RMPP/RMPPM: /etc 是 overlay, 需要 bind-mount 双写到 lower
    mkdir -p /tmp/rmkit_lower
    mount --bind / /tmp/rmkit_lower
    install_both() {
        local content="$1" abspath="$2"
        mkdir -p "$(dirname "$abspath")" "/tmp/rmkit_lower$(dirname "$abspath")"
        printf '%s\n' "$content" > "$abspath"
        printf '%s\n' "$content" > "/tmp/rmkit_lower$abspath"
        chmod 644 "$abspath" "/tmp/rmkit_lower$abspath"
    }
else
    # rm2: /etc 直接在 ext4, 直接写即可
    install_both() {
        local content="$1" abspath="$2"
        mkdir -p "$(dirname "$abspath")"
        printf '%s\n' "$content" > "$abspath"
        chmod 644 "$abspath"
    }
    # 修复 /home/root owner (rm2 出厂重置后可能设成 uid 502)
    chown root:root /home/root 2>/dev/null || true
fi

install_both "$ZZ_CONF"      "/etc/systemd/system/xochitl.service.d/zz-rmkit-cn.conf"
install_both "$UPLOAD_SVC"   "/etc/systemd/system/rmkit-cn-upload.service"
install_both "$IME_SVC"      "/etc/systemd/system/rmkit-cn-ime-http.service"
install_both "$VERSION_SVC"  "/etc/systemd/system/rmkit-cn-version.service"
install_both "$VERSION_PATH" "/etc/systemd/system/rmkit-cn-version.path"

if [ "$ARCH" = "aarch64" ]; then
    sync
    umount -l /tmp/rmkit_lower
    rmdir /tmp/rmkit_lower 2>/dev/null || true
fi
echo "[reenable] ✓ 配置文件写入完成"

systemctl daemon-reload
systemctl enable rmkit-cn-upload.service rmkit-cn-ime-http.service \
                 rmkit-cn-version.path rmkit-cn-version.service 2>/dev/null || true
systemctl start rmkit-cn-upload.service rmkit-cn-ime-http.service \
                rmkit-cn-version.path 2>/dev/null || true
echo "[reenable] ✓ 服务已启用并启动"

# fw-upgrade.sh 后台运行 (SSH 断也不中止)
echo "[reenable] 启动 fw-upgrade.sh (后台)..."
nohup bash "$RMKIT_DIR/bin/fw-upgrade.sh" > /tmp/fw-upgrade.log 2>&1 &
echo "[reenable] ✓ 完成! 观察进度: tail -f /tmp/fw-upgrade.log"
