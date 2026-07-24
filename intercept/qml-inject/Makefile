# qml-inject 原型 Makefile — 运行时 QML 注入 (shim 注入路线验证)
#
# 前提: 登录 boangs@192.168.64.4 编译机, Ferrari SDK 已就绪。
#   典型流程:
#     scp -r intercept/qml-inject boangs@192.168.64.4:/tmp/
#     ssh boangs@192.168.64.4 'cd /tmp/qml-inject && make'
#     scp boangs@192.168.64.4:/tmp/qml-inject/qml_inject-aarch64.so dist/
#
# 与 ime_hook 的差别: 这个要【真链接 Qt6】(调 QQmlComponent/QQuickItem 等 API),
#   所以走 pkg-config 拿 Qt6 的 include/lib。ime_hook 靠手读 QString 布局免链接,
#   但 QML 注入无法回避 Qt API, 必须链接。

# chiappa = Paper Pro Move (rmppm) 官方最新 SDK 3.27.0.97 (codex 5.7.119), Qt 6.8.2, cortexa55
# (设备固件 3.28 是 Qt 6.10.3, 但 6.8.2 向前兼容, ime_hook 已证明能跑)
SDK_ENV := /opt/codex/chiappa/3.27.0.97/environment-setup-cortexa55-remarkable-linux

SRC     := qml_inject.cpp
TARGET  := qml_inject-aarch64.so
VERSION := exports.version

# Qt6 模块: Qml/Quick(QML引擎+场景) Gui(QGuiApplication/QWindow) Core(QTimer/QUrl)
QT_MODULES := Qt6Quick Qt6Qml Qt6Gui Qt6Core

CXXFLAGS := -shared -fPIC -O2 -std=c++17 -fvisibility=hidden \
            -Wl,--version-script=$(VERSION) -ldl

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC) $(VERSION)
	@test -f $(SDK_ENV) || { echo "缺 chiappa SDK: $(SDK_ENV)"; exit 1; }
	bash -c 'source $(SDK_ENV) && \
	  $$CXX $(CXXFLAGS) \
	    $$(pkg-config --cflags $(QT_MODULES)) \
	    -o $@ $(SRC) \
	    $$(pkg-config --libs $(QT_MODULES))'
	@file $@
	@echo "✓ 编好: $@  (导出符号应只有 rootContext 一个:)"
	@bash -c 'source $(SDK_ENV) && $$NM -D --defined-only $@ 2>/dev/null | grep -i rootContext || true'

clean:
	rm -f $(TARGET)
