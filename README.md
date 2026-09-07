# rmkit-cn

让 reMarkable 平板说中文：系统中文界面、拼音 / 五笔输入法、AI 助手、手机扫码传文件，
以及 Paper Pro Move 上可选的 Android。

不改系统固件，不影响官方升级。装上之后不喜欢，一键卸载，设备恢复原样。

## 你会得到什么

- **中文界面**：设置、文件夹、工具栏都是中文。
- **中文输入**：任意输入框点一下键盘上的“中文”，拼音整句输入，也可切换五笔 86。
- **AI 助手**：选中文字或手写笔迹，点“AI”，润色 / 翻译 / 总结 / 问答（需要自己填一个 OpenAI 兼容接口）。
- **手机传文件**：设置里显示二维码，手机扫码就能把 PDF、字体、壁纸推到设备上。
- **高级面板**：字体、壁纸、启动器、AI 配置，还有几个小游戏。
- **Android**（仅 Paper Pro Move）：重启进 Android 用微信读书、KOReader 等应用，用完一键回到 reMarkable，两边互不影响。

## 支持的设备

| 机型 | 状态 |
|---|---|
| reMarkable Paper Pro Move | 主力机型，全部功能 |
| reMarkable Paper Pro | 支持（同一架构，测试较少） |
| reMarkable 2 | 支持（Android 除外） |

固件 3.26 以上。遇到没适配过的新固件，中文化会自动暂时关闭而不是让设备出问题，等适配后重新安装即可。

## 安装

### 准备（只需做一次）

1. 在设备上打开开发者模式：设置 → 通用 → 软件 → 启用开发者模式。**注意：这一步会清空设备上的数据，先把笔记同步到云端。**
2. 记下 SSH 密码：设置 → 帮助 → 版权与许可，翻到最底部。
3. 用 USB 线把设备连到电脑。

### 方式一：rmkit 助手（推荐，Mac / Windows 双击即用）

1. 到 [Releases](https://github.com/boangs/rmkit/releases/latest) 下载 `rmkit-assistant-mac.zip` 或 `rmkit-assistant-windows.exe`，以及载荷包 `rmkit-cn-bundle.zip`。
2. 打开助手，填入 SSH 密码，点“连接并检测”。
3. 选择载荷包，点“安装 rmkit-cn”。助手会先列出将写入的内容，装完自动检查设备是否正常。

助手只通过 USB 线和你的设备通信，没有服务器，不上传任何东西，也不会读你的笔记。它做过的每一步都记在电脑上的日志里，随时可以查看。

Mac 第一次打开如果提示“无法验证开发者”，在应用上右键 → 打开。Windows 第一次连接可能需要安装 reMarkable 的 USB 网卡驱动，设备连上电脑时系统会提示。

### 方式二：命令行脚本（Mac / Linux / WSL）

```bash
curl -fLO https://github.com/boangs/rmkit/releases/latest/download/rmkit-cn-v1.2.0.tar.gz
tar -xzf rmkit-cn-v1.2.0.tar.gz && cd rmkit-cn-v1.2.0
bash installer/install.sh
```

## 装好之后

- 输入框里点键盘上的“中文”开始打字；五笔在“设置 → 高级 → 输入法”里切换。
- 选中文字或手写内容，点“AI”。第一次要先配置：设置 → 高级 → 显示二维码 → 手机扫码填入接口地址、密钥、模型名。
- 手机扫同一个二维码可以传 PDF、字体、壁纸。

**官方系统升级后**中文化会消失，用助手或脚本重新安装一次即可，数据不受影响。

## Android（仅 Paper Pro Move）

在助手里切到“Android”页，下载或选择 `android-rmppm-bundle.zip`，点“安装 Android”。
装好后点“重启进 Android”，用完在 Android 桌面点“原厂系统”回来。安装 APK 也在这一页。

Android 和 reMarkable 用同一个系统分区，不占用另一个备用分区；Android 的应用和数据放在
设备的存储区，reMarkable 的笔记不会被动到。

## 卸载

助手里点“卸载 rmkit-cn”（或“卸载 Android”），或者：

```bash
bash installer/install.sh --uninstall
```

## 遇到问题

- 装完没变化：重启设备一次。还不行就在助手里点“重新检测”，把日志发到 [Issues](https://github.com/boangs/rmkit/issues)。
- 手写 AI 时真笔离屏幕近会画出杂线：写字时把笔拿远一点，这是设备单笔状态机的限制。
- 更多说明见 [docs/](docs/)。

## 给开发者

代码结构、安全规则、构建方法见 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [docs/development.md](docs/development.md)。
桌面助手在 [desktop/](desktop/)。

## 致谢与许可

基于 [xovi](https://github.com/asivery/xovi)、[rm-appload](https://github.com/asivery/rm-appload)、
[ghostwriter](https://github.com/awwaiid/ghostwriter)、[xovi-extensions](https://github.com/FouzR/xovi-extensions)、
[rime-frost](https://github.com/gaboolic/rime-frost) 等开源项目，详见 [NOTICE.md](NOTICE.md)。

本项目采用 [GNU GPL v3.0](LICENSE)。
