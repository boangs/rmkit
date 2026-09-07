# 由 installer/install.sh 的 tar 接收段原样提取: 从 stdin 解 payload 树到 /
  set -e
  mount -o remount,rw / 2>/dev/null || true
  mkdir -p /home/root/.local/share/rmkit-cn/fonts \
           /home/root/.local/share/rmkit-cn/screens \
           /home/root/.local/share/fonts \
           /usr/share/remarkable/xochitl/translations \
           /home/root/xovi/exthome/qt-resource-rebuilder
  # --no-same-owner 防止 tar 把 macOS 端打包时的 uid (xurx=502) 还原到设备文件,
  # 否则 /home/root owner 被改成 502 导致 sshd PAM/xochitl home 访问全卡死, 设备砖机
  cd / && tar -xzf - --no-same-owner --no-same-permissions
  # 兜底: 把 rmkit 自己投放的目录 owner 设回 root, 防御任何残留 502。
  # 只限 rmkit/xovi 路径, 绝不 -R 整个 /home/root: 单槽 Android 的系统与 /data 也在 /home/root 下,
  # 整树 chown 会把 Android 应用数据属主全改成 root (应用全崩) 并清掉 setuid 位 (2026-09-07 事故)。
  chown root:root /home/root
  chown -R root:root /home/root/rmkit-cn /home/root/xovi /home/root/.local/share/rmkit-cn 2>/dev/null || true
  chmod 755 /home/root
  [ -d /home/root/.ssh ] && chmod 700 /home/root/.ssh
  [ -f /home/root/.ssh/authorized_keys ] && chmod 600 /home/root/.ssh/authorized_keys
  exit 0
