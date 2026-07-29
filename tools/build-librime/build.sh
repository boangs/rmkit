#!/usr/bin/env bash
# 交叉编译 librime + 全套依赖到 remarkable 设备架构。
# 在构建机 (boangs@192.168.64.4) 上跑, 不是 Mac。
#
#   ./build.sh arm64   # rmpp/rmppm (chiappa SDK, cortexa55)
#   ./build.sh arm     # rm2       (rm2 SDK, cortexa7hf)
#
# 产物装到 third_party/librime/{include, lib-<goarch>}/, 供 ime-go 的 cgo 封装
# (ime-go/rime/rime.go) 静态链接。
#
# ⚠ 交叉编译 6 个 C++ 库是本工程最大的不确定性 —— 每个库的 toolchain 适配都可能
# 踩坑 (Boost b2 的 architecture、marisa 的 autotools host、OpenCC 的数据文件)。
# 本脚本是"结构 + 起点", 需在构建机上逐库调通。失败先看单库的 configure/cmake log。
set -euo pipefail

GOARCH="${1:?用法: build.sh arm64|arm}"
case "$GOARCH" in
  arm64)
    SDK_ENV=/opt/codex/chiappa/3.27.0.97/environment-setup-cortexa55-remarkable-linux ;;
  arm)
    SDK_ENV=/opt/codex/rm2/3.26.0.68/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi ;;
  *) echo "未知架构: $GOARCH (要 arm64 或 arm)"; exit 1 ;;
esac
[ -f "$SDK_ENV" ] || { echo "缺 SDK: $SDK_ENV (要在构建机上跑)"; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# 产物根目录, 可用 RIME_PREFIX 覆盖 (构建机上独立跑时指向 /tmp, 再 scp 拉回本地
# repo 的 third_party/librime/)。
PREFIX="${RIME_PREFIX:-$ROOT/third_party/librime}"
LIBDIR="$PREFIX/lib-$GOARCH"
INCDIR="$PREFIX/include"
WORK="/tmp/rime-build-$GOARCH"
JOBS="$(nproc)"

mkdir -p "$LIBDIR" "$INCDIR" "$WORK"

# shellcheck disable=SC1090
source "$SDK_ENV"
# SDK env 导出 $CC $CXX $CFLAGS $LDFLAGS $SDKTARGETSYSROOT $CONFIGURE_FLAGS 等。
# autotools host 三元组: 按架构定, 不从 $CC 猜 ($CC 带 flags, 且 SDK 的
# cortexa55-remarkable-linux 不是合法 config.sub 三元组 —— marisa configure
# 会报 machine not recognized)。
case "$GOARCH" in
  arm64) HOST_TRIPLE="aarch64-remarkable-linux" ;;
  arm)   HOST_TRIPLE="arm-remarkable-linux-gnueabi" ;;
esac
echo "== 架构=$GOARCH triple=$HOST_TRIPLE sysroot=$SDKTARGETSYSROOT =="

# cmake 交叉编译: 用 Yocto SDK 自带的 toolchain file (env 已导出
# $CMAKE_TOOLCHAIN_FILE 指向 OEToolchainConfig.cmake)。它正确拆分 $CXX 的
# 编译器路径与 flags —— 手搓 -DCMAKE_CXX_COMPILER="$CXX" 会因 $CXX 带
# -mcpu/--sysroot 参数而失败。
# FIND_ROOT_PATH 显式列 target sysroot (含白嫖的 Boost/glog) + stage (先编的
# 几个依赖), 让 librime 两处都能 find_package 到。
CMAKE_COMMON=(
  -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE"
  -DCMAKE_INSTALL_PREFIX="$WORK/stage"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_FIND_ROOT_PATH="$SDKTARGETSYSROOT;$WORK/stage"
  -DCMAKE_PREFIX_PATH="$WORK/stage"
)
export PKG_CONFIG_PATH="$WORK/stage/lib/pkgconfig"
mkdir -p "$WORK/stage"

fetch() { # $1=url $2=dir
  local d="$WORK/$2"
  [ -d "$d" ] && return 0
  echo "-- 拉取 $2"
  ( cd "$WORK" && wget -qO- "$1" | tar xz )
}

# ── 1. yaml-cpp (cmake, 干净) ─────────────────────────────────────
build_yamlcpp() {
  fetch https://github.com/jbeder/yaml-cpp/archive/refs/tags/0.8.0.tar.gz yaml-cpp-0.8.0
  cmake -S "$WORK/yaml-cpp-0.8.0" -B "$WORK/yaml-cpp-0.8.0/b" "${CMAKE_COMMON[@]}" \
    -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
  cmake --build "$WORK/yaml-cpp-0.8.0/b" -j"$JOBS"
  cmake --install "$WORK/yaml-cpp-0.8.0/b"
}

# ── 2. LevelDB (cmake, userdb 存储) ───────────────────────────────
build_leveldb() {
  fetch https://github.com/google/leveldb/archive/refs/tags/1.23.tar.gz leveldb-1.23
  cmake -S "$WORK/leveldb-1.23" -B "$WORK/leveldb-1.23/b" "${CMAKE_COMMON[@]}" \
    -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF
  cmake --build "$WORK/leveldb-1.23/b" -j"$JOBS"
  cmake --install "$WORK/leveldb-1.23/b"
}

# ── 3. marisa-trie (autotools, 静态词库) ──────────────────────────
build_marisa() {
  fetch https://github.com/s-yata/marisa-trie/archive/refs/tags/v0.2.6.tar.gz marisa-trie-0.2.6
  ( cd "$WORK/marisa-trie-0.2.6"
    [ -f configure ] || { autoreconf -i 2>/dev/null || (aclocal && automake --add-missing && autoconf); }
    ./configure --host="$HOST_TRIPLE" --prefix="$WORK/stage" \
      --enable-static --disable-shared --disable-tools \
      CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS"
    make -j"$JOBS" && make install )
}

# ── 4. OpenCC (cmake, 繁简; 需要数据文件, 设备端也要 opencc data) ──
build_opencc() {
  fetch https://github.com/BYVoid/OpenCC/archive/refs/tags/ver.1.1.7.tar.gz OpenCC-ver.1.1.7
  # 注: OpenCC 编译期会用 host 工具生成字典二进制。交叉编译时需 -DUSE_SYSTEM_* 或
  # 先在 host 编一份 opencc_dict 工具。这里是已知坑点, 构建机上按报错补 host 工具路径。
  cmake -S "$WORK/OpenCC-ver.1.1.7" -B "$WORK/OpenCC-ver.1.1.7/b" "${CMAKE_COMMON[@]}" \
    -DBUILD_DOCUMENTATION=OFF -DENABLE_GTEST=OFF
  cmake --build "$WORK/OpenCC-ver.1.1.7/b" -j"$JOBS"
  cmake --install "$WORK/OpenCC-ver.1.1.7/b"
}

# ── 5. Boost ── 跳过: chiappa/rm2 SDK sysroot 里已带 Boost + glog
# (确认于构建机: libboost_{regex,filesystem,locale,system} 齐)。librime cmake
# 通过 CMAKE_SYSROOT 直接 find_package(Boost) 命中, 不用自己编。
# build_boost() 保留占位, 若某架构 sysroot 无 Boost 再启用上面注释的 b2 流程。

# ── 6. librime 本体 (cmake, BUILD_STATIC) ─────────────────────────
build_librime() {
  fetch https://github.com/rime/librime/archive/refs/tags/1.11.2.tar.gz librime-1.11.2
  # librime 用自带的老式 Find*.cmake 模块 (FindYamlCpp/FindLevelDb/FindMarisa),
  # 它们靠 find_path/find_library 搜索。而 Yocto toolchain file 把
  # CMAKE_FIND_ROOT_PATH_MODE_{INCLUDE,LIBRARY} 设成 ONLY —— 只在 target sysroot
  # 里找, 看不见我们编到 $WORK/stage 的依赖 → "Could not find yaml-cpp library"。
  # 对策: 把三个依赖的路径变量直接喂给 cmake (跳过搜索), 并放宽 ROOT_PATH_MODE
  # 为 BOTH 让 OpenCC/Boost 的 config 模式也能在 stage + sysroot 两处命中。
  local S="$WORK/stage"
  cmake -S "$WORK/librime-1.11.2" -B "$WORK/librime-1.11.2/b" "${CMAKE_COMMON[@]}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DYamlCpp_INCLUDE_PATH="$S/include" \
    -DYamlCpp_NEW_API="$S/include" \
    -DYamlCpp_LIBRARY="$S/lib/libyaml-cpp.a" \
    -DLevelDb_INCLUDE_PATH="$S/include" \
    -DLevelDb_LIBRARY="$S/lib/libleveldb.a" \
    -DMarisa_INCLUDE_PATH="$S/include" \
    -DMarisa_LIBRARY="$S/lib/libmarisa.a" \
    -DOpencc_INCLUDE_PATH="$S/include" \
    -DOpencc_LIBRARY="$S/lib/libopencc.a" \
    -DBUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TEST=OFF -DENABLE_LOGGING=OFF -DBUILD_DATA=OFF
  cmake --build "$WORK/librime-1.11.2/b" -j"$JOBS"
  cmake --install "$WORK/librime-1.11.2/b"
}

# ── 收集产物到 cgo 能找到的位置 ───────────────────────────────────
collect() {
  cp -r "$WORK/stage/include/"* "$INCDIR/" 2>/dev/null || true
  find "$WORK/stage" -name '*.a' -exec cp {} "$LIBDIR/" \;
  echo "== 完成: $LIBDIR =="
  ls -la "$LIBDIR"
}

# 可选第二参数 = 只跑单步 (调试用): build.sh arm64 build_yamlcpp
STEP="${2:-}"
if [ -n "$STEP" ]; then
  "$STEP"; collect
else
  # Boost + glog 白嫖 SDK sysroot, 只编这四个 + librime 本体
  build_yamlcpp
  build_leveldb
  build_marisa
  build_opencc
  build_librime
  collect
fi
