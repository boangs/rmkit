# qml-inject — 运行时 QML 注入构建 (瘦 hook + 胖库, 即历史文档里的"方案 A")
#
# 在远程 Linux 编译机上跑, 不是 Mac (macOS 上没有 chiappa SDK):
#   scp -r intercept/qml-inject boangs@192.168.64.4:/tmp/
#   ssh   boangs@192.168.64.4 'cd /tmp/qml-inject && make'
#   scp   'boangs@192.168.64.4:/tmp/qml-inject/qml_inject*-aarch64.so' dist/
#
# 产物名直接就是 dist/ 里的名字, 拷过去不用改名 —— installer/install.sh 按
# $QML_INJECT_NAME / $QML_INJECT_IMPL_NAME 找这两个文件, 改名会让它静默跳过部署。
#
# chiappa = Paper Pro Move (rmppm) 官方最新 SDK 3.27.0.97 (codex 5.7.119), Qt 6.8.2, cortexa55
# (设备固件 3.28 是 Qt 6.10.3, 但 6.8.2 向前兼容, ime_hook 与本注入均已实测能跑)
SDK_ENV := /opt/codex/chiappa/3.27.0.97/environment-setup-cortexa55-remarkable-linux
# rm2 (armv7hf): 用最老的 3.26.0.68 SDK 编, 向前兼容 3.26+ 全部 rm2 固件
SDK_ENV_A7 := /opt/codex/rm2/3.26.0.68/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi

# Qt6 模块: Qml/Quick(QML引擎+场景) Gui(QGuiApplication/QWindow) Core(QTimer/QUrl)
QT_MODULES := Qt6Quick Qt6Qml Qt6Gui Qt6Core

THIN := qml_inject-aarch64.so
IMPL := qml_inject_impl-aarch64.so
THIN7 := qml_inject-armv7.so
IMPL7 := qml_inject_impl-armv7.so

.PHONY: all aarch64 armv7 clean probe

all: aarch64 armv7
aarch64: $(THIN) $(IMPL)
armv7: $(THIN7) $(IMPL7)

# ── 瘦 hook: 进 LD_PRELOAD, 绝不链接 Qt ──────────────────────────
# 为什么必须不链 Qt: 链 Qt 的 .so 一旦进 LD_PRELOAD, Qt 库会在 xochitl 自己的
# 静态初始化之前被加载, 破坏初始化顺序 → 启动即崩 (实测: 链 Qt 的崩, 不链的存活;
# ime_hook 能工作正是因为它手读 QString 布局、不链 Qt)。所以这里只插桩
# QQmlEngine::rootContext() 抓 engine 指针, 纯 dlsym RTLD_NEXT 转发, 再延迟
# dlopen 胖库 —— 那时 Qt 已就绪, 等价于 Qt 插件的加载时机, 安全。
#
# -fvisibility=hidden 与 version script 的坑: hidden 会压过 version script 的
# global:, 符号进不了动态表 → LD_PRELOAD 抢不到。hook 函数必须在源码里显式带
# __attribute__((visibility("default"))), 见 thin_hook.cpp。
$(THIN): thin_hook.cpp exports.version
	@test -f $(SDK_ENV) || { echo "缺 chiappa SDK: $(SDK_ENV) (要在编译机上 make)"; exit 1; }
	bash -c 'source $(SDK_ENV) && $$CXX -shared -fPIC -O2 -fvisibility=hidden \
	  -Wl,--version-script=exports.version -o $@ thin_hook.cpp -lpthread -ldl'
	@bash -c 'source $(SDK_ENV) && $$NM -D --defined-only $@ | grep rootContext' \
	  || { echo "✗ rootContext 没进动态符号表, LD_PRELOAD 会抢不到"; exit 1; }
	@echo "✓ 瘦 hook: $@"

# ── 胖库: 由瘦 hook dlopen, 链接 Qt6 ────────────────────────────
# 导出 pw_inject(engine)。内部必须 QMetaObject::invokeMethod 到 GUI 主线程再碰
# QML —— 在 worker 线程直接操作场景树会崩。
$(IMPL): qml_inject_impl.cpp exports-impl.version
	@test -f $(SDK_ENV) || { echo "缺 chiappa SDK: $(SDK_ENV) (要在编译机上 make)"; exit 1; }
	bash -c 'source $(SDK_ENV) && $$CXX -shared -fPIC -O2 -std=c++17 -fvisibility=hidden \
	  -Wl,--version-script=exports-impl.version \
	  $$(pkg-config --cflags $(QT_MODULES)) \
	  -o $@ qml_inject_impl.cpp \
	  $$(pkg-config --libs $(QT_MODULES))'
	@bash -c 'source $(SDK_ENV) && $$NM -D --defined-only $@ | grep pw_inject' \
	  || { echo "✗ pw_inject 没导出"; exit 1; }
	@echo "✓ 胖库: $@"

# ── armv7 (rm2) 版: 同源码, 换 SDK ─────────────────────────────
$(THIN7): thin_hook.cpp exports.version
	@test -f $(SDK_ENV_A7) || { echo "缺 rm2 SDK: $(SDK_ENV_A7) (要在编译机上 make)"; exit 1; }
	bash -c 'source $(SDK_ENV_A7) && $$CXX -shared -fPIC -O2 -fvisibility=hidden \
	  -Wl,--version-script=exports.version -o $@ thin_hook.cpp -lpthread -ldl'
	@bash -c 'source $(SDK_ENV_A7) && $$NM -D --defined-only $@ | grep rootContext' \
	  || { echo "✗ rootContext 没进动态符号表, LD_PRELOAD 会抢不到"; exit 1; }
	@echo "✓ 瘦 hook: $@"

$(IMPL7): qml_inject_impl.cpp exports-impl.version
	@test -f $(SDK_ENV_A7) || { echo "缺 rm2 SDK: $(SDK_ENV_A7) (要在编译机上 make)"; exit 1; }
	bash -c 'source $(SDK_ENV_A7) && $$CXX -shared -fPIC -O2 -std=c++17 -fvisibility=hidden \
	  -Wl,--version-script=exports-impl.version \
	  $$(pkg-config --cflags $(QT_MODULES)) \
	  -o $@ qml_inject_impl.cpp \
	  $$(pkg-config --libs $(QT_MODULES))'
	@bash -c 'source $(SDK_ENV_A7) && $$NM -D --defined-only $@ | grep pw_inject' \
	  || { echo "✗ pw_inject 没导出"; exit 1; }
	@echo "✓ 胖库: $@"

# 历史探针 (noqt_probe.cpp): 验证"不链 Qt 也能插桩到 Qt 符号"的最小实验,
# 已被瘦 hook 取代, 保留供排查插桩本身是否生效。
probe: noqt_probe.cpp exports-noqt.version
	bash -c 'source $(SDK_ENV) && $$CXX -shared -fPIC -O2 \
	  -Wl,--version-script=exports-noqt.version -o noqt_probe.so noqt_probe.cpp -ldl'

clean:
	rm -f $(THIN) $(IMPL) $(THIN7) $(IMPL7) noqt_probe.so
