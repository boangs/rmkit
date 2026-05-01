# ime_hook 双架构 Makefile
#
# 前提：登录 boangs@192.168.64.4 编译机，SDK 已就绪。
#   Ferrari (aarch64 / Paper Pro / Paper Pro Move): /opt/codex/ferrari/5.0.58-dirty
#   RM2     (armv7  / reMarkable 2):                /opt/codex/rm2/3.26.0.68
#
# 本机（Mac）不要执行 `make`。典型流程：
#   scp ime_hook.cpp Makefile boangs@192.168.64.4:/tmp/hookbuild/
#   ssh boangs@192.168.64.4 'cd /tmp/hookbuild && make all'
#   scp boangs@192.168.64.4:/tmp/hookbuild/ime_hook-*.so dist/
#
# 目标：
#   make aarch64  → ime_hook-aarch64.so（Paper Pro / Paper Pro Move）
#   make armv7    → ime_hook-armv7.so（reMarkable 2）
#   make all      → 两份都编
#   make clean

FERRARI_ENV := /opt/codex/ferrari/5.0.58-dirty/environment-setup-cortexa53-crypto-remarkable-linux
RM2_ENV     := /opt/codex/rm2/3.26.0.68/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi

SRC      := ime_hook.cpp
CXXFLAGS := -shared -fPIC -O2 -fvisibility=hidden \
            -Wl,--version-script=exports.version \
            -ldl

# 导出表：只保留 Qt mangled 符号，其余全 hidden
# 用 version script 保证 dlsym(RTLD_NEXT,...) 能找到 libQt5Gui 里的真身，
# 同时 .so 自身只暴露这一个符号。
EXPORTS_VERSION := exports.version

.PHONY: all aarch64 armv7 clean

all: aarch64 armv7

aarch64: ime_hook-aarch64.so

armv7: ime_hook-armv7.so

$(EXPORTS_VERSION):
	@printf '{\n  global:\n    _ZN17QInputMethodEvent15setCommitStringERK7QStringii;\n    _ZN22QGuiApplicationPrivate15processKeyEventEPN29QWindowSystemInterfacePrivate8KeyEventE;\n  local: *;\n};\n' > $@

ime_hook-aarch64.so: $(SRC) $(EXPORTS_VERSION)
	@test -f $(FERRARI_ENV) || { echo "缺 Ferrari SDK: $(FERRARI_ENV)"; exit 1; }
	bash -c 'source $(FERRARI_ENV) && $$CXX $(CXXFLAGS) -o $@ $(SRC)'
	@file $@

ime_hook-armv7.so: $(SRC) $(EXPORTS_VERSION)
	@test -f $(RM2_ENV) || { echo "缺 RM2 SDK: $(RM2_ENV)"; exit 1; }
	bash -c 'source $(RM2_ENV) && $$CXX $(CXXFLAGS) -o $@ $(SRC)'
	@file $@

clean:
	rm -f ime_hook-*.so $(EXPORTS_VERSION)
