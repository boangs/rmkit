# Paper Pro Move 单槽 Android（源码与配方）

Release 里 `android-rmppm-bundle.zip` / `android-rmppm-bundle-lite.zip` 分发的二进制都从这里构建。
设备端安装逻辑在 [`../desktop/internal/scripts/android-install.sh`](../desktop/internal/scripts/android-install.sh)。

## 架构

reMarkable 与 Android 共用当前系统分区（不切槽），Android 系统与数据放在两槽共享的 /home：

- `/sbin/init` 换成 [`host/init-wrapper.tmpl.sh`](host/init-wrapper.tmpl.sh)：没有 `/.boot-android-mode` 标志就原样 exec systemd；有标志则先删标志、把 `/boot/fitImage.ahab` 链接复位回出厂内核、清本槽启动错误计数，再 exec `rm-android-init-ss`。任何失败都回到 reMarkable。
- 进 Android：[`host/boot-android.sh`](host/boot-android.sh) 置标志 + 内核链接指向 `fitImage.ahab-android` + 重启。
- 回 reMarkable：Android 桌面“原厂系统”→ `rm-native-controls` 写 `/run/paper-stock-orderly-requested` → `rm-android-init-ss` 优雅重启。**绝不动 eMMC 启动分区**（`mmc bootpart` 就是 `rootdev --switch` 的实现，会切到另一个槽）。
- rootfs 只多约 27MB：android 内核、`/lib/modules/6.12.49+git+f21cbcc9ed9a`、四个宿主程序、`/etc/paperhome/udhcpd-usb.conf`、`android-kernel-revert.service`（后两者必须写到 rootfs 下层，Android 模式没有 /etc overlay）。

## 目录

| 目录 | 内容 | 来源 / 许可 |
|---|---|---|
| `rm-android-init/` | Android 的 PID 1（挂 cgroup/binderfs、加载模块、解密 /home、起触摸中继与显示桥、监督 reDroid）。单槽改动：bind `/home/root/android-system` → `/android`；不切 eMMC 启动分区；不 fork；模块列表加 `ashmem_linux`；首启时跳过 rmppm-home 绑定 | 派生自 skdlzlvk/paper-pro-move-dualboot-installer `src/runtime/rm-android-init.c`，GPL-3.0 |
| `rm-epd-bridge/` | HWC 帧 → 墨水屏的显示桥 v55。适配固件 3.28（5.8.x）的 libqsgepaper：去掉 EPContentMap，swapBuffers 新签名，EPFramebuffer 成员偏移 -0x20 | 派生自同一上游，GPL-3.0；`third_party/oxide/epframebuffer.h` 来自 Eeems-Org/oxide，MIT，按 5.8.x 导出符号修订 |
| `rm-touch-relay/` | Elan 触摸 → uinput 中继（掌拒、导航手势） | 同上游，GPL-3.0 |
| `host/` | `rm-native-controls`（PaperHome 侧的宿主控制：回原厂、前灯、健康探针）、启动器、init 包装与 systemd 模板、USB DHCP 配置 | 脚本派生自同上游，GPL-3.0 |
| `ashmem/` | anbox 移植的 ashmem 内核模块（微信读书等自带旧 CursorWindow 的应用需要） | GPL-2.0 |
| `android-system/` | 放进 reDroid 系统镜像的调优脚本、rc 与输入设备 idc | 本项目 |
| `kernel/` | 自编内核的 config（pxpm 系列；`fitImage.ahab-android` = pxpm4） | 见下 |

## 构建

工具链：reMarkable 3.27 SDK（`/opt/codex/chiappa/3.27.0.97/`，`source environment-setup-cortexa55-remarkable-linux`）。

```bash
# rm-android-init-ss
$CC -O2 -Wall -o rm-android-init-ss rm-android-init/rm-android-init.c
# rm-touch-relay
$CC -O2 -o rm-touch-relay rm-touch-relay/rm-touch-relay.c
# rm-epd-bridge: 先把设备 (3.28) 的 /usr/lib/plugins/scenegraph/libqsgepaper.so 放到 rm-epd-bridge/lib58/
cd rm-epd-bridge && qmake6 rm-epd-bridge.pro && make
```

内核：基于 github.com/reMarkable/linux-imx-rm `rmpp_6.12.49_v3.27.x` 分支 + `kernel/android-slot-pxpm.config`。pxpm4 相对 pxpm 多两处补丁（`drivers/dma/of-dma.c` 控制器节点 disabled 时回 ENODEV 走 PIO；`chiappa.dtsi` 禁用 edma1/edma2 并使能 epxp）。没有这两处，开了 eDMA 后 lpspi/lpi2c 永久 EPROBE_DEFER，触摸与 NFC 全部消失。补丁源码在构建机 `~/build/linux-imx-*/`（搜 `rmkit`），待整理成 patch 文件入库。

Android 系统包（`android-system.tar.gz`）= reDroid 12 arm64 镜像 + `android-system/` 里的调优文件 + PaperHome，从已跑通的设备上 `tar -czf --numeric-owner` 打包；属主必须保留（`chown -R` 会毁掉它）。

## 打包成载荷

```bash
cd ../desktop
go run ./cmd/mkbundle -component android-rmppm -android-dir <目录> -out dist/android-rmppm-bundle.zip
```

`<目录>` 里放 `fitImage.ahab-android`、`modules.tar.gz`（含 `extra/ashmem_linux.ko`）、四个宿主程序、`propset`、`host/` 的五个文件，以及可选的 `android-system.tar.gz`（省略即为 lite 热修包）。
