#!/usr/bin/env bash
# 在构建机上生成随安装包下发的两个 librime 数据包。
#
#   ./build-dict.sh [rime-frost 源码目录] [输出目录]
#   默认: ./build-dict.sh /tmp/rime-frost /tmp/rime-dist
#
# 产物:
#   rime-runtime-data.tar.gz  ~2.9M  解到 shared dir (opencc/ + en_dicts/ + custom_phrase.txt)
#   rime-prebuilt.tar.gz      ~31M   解到 user dir   (build/ 预编译产物)
#
# 关键点: 词库编译**只在构建机上做**, 设备端永不编译。
#   - 设备端冷编译实测 110 秒、峰值 RssAnon 881MB (rm2 的 1GB 内存扛不住),
#     且编译完堆不归还 OS, 进程会一直吃着 467MB。
#   - 用预编译产物热启动只要 1 秒、稳态 RssAnon 13MB。
#   - 产物是 OffsetPtr<T,int32_t> 偏移量格式, 不含原生指针, x86_64 编译的
#     .table.bin/.prism.bin/.reverse.bin 在 aarch64 (rmpp/rmppm) 上实测直接可用。
set -euo pipefail

SRC="${1:-/tmp/rime-frost}"
OUT="${2:-/tmp/rime-dist}"
WORK="/tmp/rime-dict-build"
LIBRIME_VER="1.11.2"
HOST="$WORK/host"

[ -d "$SRC" ] || { echo "缺 rime-frost 源码: $SRC (git clone https://github.com/gaboolic/rime-frost)"; exit 1; }

# ── 1. host 版 librime (只为拿 rime_deployer 这个编译工具) ────────────
# 注意: 这跟 build.sh 交叉编译出的设备版 librime 是两码事, 互不干扰。
build_host_librime() {
  [ -x "$HOST/b/bin/rime_deployer" ] && return 0
  echo "== 编译 host 版 librime (取 rime_deployer) =="
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    libyaml-cpp-dev libleveldb-dev libmarisa-dev libopencc-dev \
    libboost-regex-dev libboost-filesystem-dev libboost-system-dev cmake g++
  local tarball="$WORK/librime-$LIBRIME_VER"
  if [ ! -d "$tarball" ]; then
    mkdir -p "$WORK"
    ( cd "$WORK" && wget -qO- \
      "https://github.com/rime/librime/archive/refs/tags/$LIBRIME_VER.tar.gz" | tar xz )
  fi
  # ENABLE_LOGGING=OFF: 免依赖 glog (Ubuntu 24.04 没有 libglog-dev 包)
  cmake -S "$tarball" -B "$HOST/b" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TEST=OFF -DBUILD_DATA=OFF -DBUILD_SHARED_LIBS=ON -DENABLE_LOGGING=OFF
  cmake --build "$HOST/b" -j"$(nproc)"
}

# ── 2. 拼出编译用的完整源码树 ─────────────────────────────────────────
# 这棵树只是 rime_deployer 的输入, 不下发到设备。
stage_source() {
  local ST="$WORK/src/rime"
  rm -rf "$WORK/src" && mkdir -p "$ST"
  ( cd "$SRC"
    # 词库目录: 保留细胞词库 (实测有效, 如 jianaifeigong→兼爱非攻,
    # 去掉则退化成"简爱费工")
    # cn_dicts_wb: 五笔 86 码表 (chars + words, 4M), 供 rime_frost_wubi86 方案
    for d in cn_dicts cn_dicts_cell cn_dicts_wb en_dicts opencc; do cp -r "$d" "$ST/"; done
    for f in rime_frost.schema.yaml rime_frost.dict.yaml \
             melt_eng.schema.yaml melt_eng.dict.yaml \
             radical_pinyin.schema.yaml radical_pinyin.dict.yaml \
             rime_frost_aux.schema.yaml rime_frost_aux.dict.yaml \
             rime_frost_wubi86.schema.yaml rime_frost_wubi86.dict.yaml \
             symbols_v.yaml symbols.yaml \
             default.yaml punctuation.yaml key_bindings.yaml \
             custom_phrase.txt LICENSE; do
      cp "$f" "$ST/"
    done )
  # tencent.dict.yaml 在 rime_frost.dict.yaml 的 import_tables 里是注释掉的,
  # 11M 纯废重量, 不进编译树。
  rm -f "$ST/cn_dicts/tencent.dict.yaml"
  # 只部署 rime_frost (拼音) + rime_frost_wubi86 (五笔 86) 两个方案, 否则会把
  # 双拼/仓颉/注音全编一遍。方案由 ime-server 的 /rime/schema 接口切换 (高级面板)。
  # 放 shared dir 里的 default.custom.yaml 同样生效。
  cat > "$ST/default.custom.yaml" <<'YAML'
# rmkit-cn: 只部署 拼音 + 五笔86 两个方案
patch:
  schema_list:
    - schema: rime_frost
    - schema: rime_frost_wubi86
  # 每页 5 个候选 (上游默认 8)。reMarkable 屏幕窄, 候选栏是一条横向单行,
  # 8 个会挤满甚至溢出; 5 个正好, 多的翻页。
  menu/page_size: 5
YAML
  # schema 自己的 menu/page_size 会覆盖 default 的, 所以也要 patch 方案级配置。
  for sc in rime_frost rime_frost_wubi86; do
    cat > "$ST/$sc.custom.yaml" <<'YAML'
# rmkit-cn: 候选每页 5 个 (方案级, 覆盖 schema 里的 page_size: 8)
patch:
  menu/page_size: 5
YAML
  done
  # 不带的东西, 都是实测确认无效的:
  #   essay.txt          已无引用
  #   zh-moqi.gram (7M)  schema 里的 grammar: 需要 librime-octagram 插件,
  #                      我们没编插件 → poet.cc 的 Grammar::Require("grammar")
  #                      返回 nullptr → 整个语言模型静默不生效
  #   lua/               所有 lua_translator@* / lua_filter@* 需要 librime-lua
  #                      插件, 同样没编 → 组件创建失败被跳过
  #   others/ cn_dicts_common/ cn_dicts_wb/ 及双拼/五笔/仓颉 schema
}

# ── 3. 编译词库 ───────────────────────────────────────────────────────
# rime_deployer 的参数顺序是 <user_data_dir> <shared_data_dir>,
# 产物落在 <user_data_dir>/build/ —— 顺序写反会把 build/ 拉到源码树里。
compile_dict() {
  echo "== 编译词库 (约 3 分钟) =="
  rm -rf "$WORK/out" && mkdir -p "$WORK/out"
  LD_LIBRARY_PATH="$HOST/b/lib" "$HOST/b/bin/rime_deployer" \
    --build "$WORK/out" "$WORK/src/rime"
  [ -f "$WORK/out/build/rime_frost.table.bin" ] || { echo "编译失败: 没生成 table.bin"; exit 1; }
}

# ── 4. 打包 ───────────────────────────────────────────────────────────
# shared dir 只需要运行期真正会读的东西。.dict.yaml/.schema.yaml 等源文件
# 已经全部编进 build/ 里, 运行期不再读取 —— 实测去掉后候选逐字相同,
# shared 目录从 88M 缩到 6.9M。
pack() {
  mkdir -p "$OUT"
  local RT="$WORK/rt/rime"
  rm -rf "$WORK/rt" && mkdir -p "$RT"
  cp -r "$WORK/src/rime/opencc" "$WORK/src/rime/en_dicts" "$RT/"
  cp "$WORK/src/rime/custom_phrase.txt" "$WORK/src/rime/LICENSE" "$RT/"
  tar --owner=0 --group=0 --numeric-owner -czf "$OUT/rime-runtime-data.tar.gz" \
    -C "$WORK/rt" rime
  tar --owner=0 --group=0 --numeric-owner -czf "$OUT/rime-prebuilt.tar.gz" \
    -C "$WORK/out" build
  echo "== 产物 =="
  ls -l "$OUT"/rime-runtime-data.tar.gz "$OUT"/rime-prebuilt.tar.gz
  sha256sum "$OUT"/rime-runtime-data.tar.gz "$OUT"/rime-prebuilt.tar.gz
}

build_host_librime
stage_source
compile_dict
pack
echo "== 完成。安装集成见 tools/build-librime/DICT-PACKAGING.md =="
