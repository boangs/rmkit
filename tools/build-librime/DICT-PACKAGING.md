# librime 词库打包与安装集成

设备端**永不编译词库**。词库在构建机上用 `rime_deployer` 编译好，随安装包下发。

## 两个包

| 包 | 体积 | 解包目标 | 内容 |
|---|---|---|---|
| `rime-runtime-data.tar.gz` | 2.9 MB (解开 6.9 MB) | `/home/root/rmkit-cn/` → 得到 `rime/` | `opencc/`、`en_dicts/`、`custom_phrase.txt`、`LICENSE` |
| `rime-prebuilt.tar.gz` | 31 MB (解开 72.4 MB) | `/home/root/.rmkit-rime/` → 得到 `build/` | `default.yaml` + 4 个方案各自的 `.schema.yaml`/`.table.bin`/`.prism.bin`/`.reverse.bin`，共 17 个文件 |

设备磁盘占用合计 **79.3 MB**。

两个包都带顶层目录前缀（`rime/` 和 `build/`），所以 `tar xzf ... -C <父目录>` 即可，不会散落。

## 设备上的目录布局

| 目录 | 角色 | 可写 | 说明 |
|---|---|---|---|
| `/home/root/rmkit-cn/rime` | librime `shared_data_dir` | 只读 | 运行期只读 opencc 数据和 `en_dicts/`、`custom_phrase.txt` |
| `/home/root/.rmkit-rime` | librime `user_data_dir` | 可写 | 放 `build/`（预编译产物）+ `rime_frost.userdb/`（自学习）+ `user.yaml`/`installation.yaml` |

两个路径在 `ime-go/cmd/ime-server/session.go` 里可用 `RIME_SHARED_DIR` / `RIME_USER_DIR` 覆盖。

`.dict.yaml` / `.schema.yaml` / `symbols_v.yaml` 等源文件**不下发**——它们已经全部编进 `build/` 里，运行期不再读取。实测去掉后候选结果逐字相同，shared 目录从 88 MB 缩到 6.9 MB。

## 安装脚本步骤

**顺序不能改**，理由见下一节。

```sh
SHARED=/home/root/rmkit-cn/rime
USERD=/home/root/.rmkit-rime

# 1. 解包
mkdir -p "$(dirname "$SHARED")" "$USERD"
rm -rf "$SHARED"
tar xzf rime-runtime-data.tar.gz -C "$(dirname "$SHARED")"   # → $SHARED
rm -rf "$USERD/build"
tar xzf rime-prebuilt.tar.gz -C "$USERD"                     # → $USERD/build

# 2. 预建 librime 运行期会在 user dir 根目录创建的所有条目。
#    ★ 这一步是正确性关键, 漏了会导致第二次启动触发 33 秒重编译 ★
mkdir -p "$USERD/rime_frost.userdb" "$USERD/sync" "$USERD/trash"

# 3. installation.yaml —— 字段必须和 rime.go 里 RimeTraits 设的完全一致,
#    否则 InstallationUpdate 每次启动都会重写这个文件, 顶掉 user dir 的 mtime。
[ -f "$USERD/installation.yaml" ] || cat > "$USERD/installation.yaml" <<EOF
distribution_code_name: "rmkit-cn"
distribution_name: "rmkit-cn"
distribution_version: 1.0
install_time: "$(date)"
installation_id: "$(cat /proc/sys/kernel/random/uuid)"
rime_version: 1.11.2
EOF

# 4. 最后写时间戳。先建文件再用 > 原地截断重写 ——
#    `>` 截断已存在的文件不会改父目录 mtime, 而新建文件会。
: > "$USERD/user.yaml"
printf 'var:\n  last_build_time: %s\n' "$(date +%s)" > "$USERD/user.yaml"
```

设备是 BusyBox：没有 `install(1)`，`head -N` / `head -c` 不支持（用 `sed -n '1,5p'` / `cut -c1-300`），但 `printf '%d' "'n"`、`/proc/sys/kernel/random/uuid`、`wget` 都可用。

## 为什么是这个顺序（复用机制的真实逻辑）

`rime.go` 调的是 `start_maintenance(full_check=0)`。**判据不是 `build/` 里文件的 mtime**，而是 librime `DetectModifications::Run`（`src/rime/lever/deployment_tasks.cc`）：

```cpp
for (auto dir : {user_data_dir, shared_data_dir}) {
  last_modified = max(last_modified, last_write_time(dir));        // ← 目录自身 mtime
  for (每个直接子项)
    if (后缀 == ".yaml" && 文件名 != "user.yaml")
      last_modified = max(last_modified, last_write_time(entry));  // ← 只看顶层, 不递归
}
user_config->GetInt("var/last_build_time", &last_build_time);      // ← 读 user.yaml
if (last_modified > last_build_time) return true;                  // → 触发全量重编译
```

即：**`user.yaml` 里的 `var/last_build_time` 必须 ≥ 两个 data dir 的目录 mtime**（我们不下发顶层 `.yaml`，所以只剩目录 mtime 这一项）。

### 踩过的坑：第二次启动会重编译

按"解包 → 写 stamp"装完，**第一次**启动确实 1 秒。但用户一打字，librime 会在 user dir 根目录创建 `rime_frost.userdb/`，这个**新建目录项**把 user dir 的 mtime 顶到 stamp 之后 → **第二次**启动 `last_modified > last_build_time`，触发 33 秒重编译。

修复就是上面第 2 步：安装时把 `rime_frost.userdb/`、`sync/`、`trash/` 全部预建出来，运行期不再有新条目产生，user dir 的 mtime 就被冻结在安装时刻。

同理第 3 步：`installation.yaml` 缺失时 `InstallationUpdate` 会创建它（这个任务在 `detect_modifications` **之前**无条件执行），同样会顶掉目录 mtime。字段对不上时它也会重写。

第 4 步的 `>` 原地截断：新建文件改父目录 mtime，截断已有文件不改。所以先建空文件（此时目录 mtime 更新），再取 `date +%s` 写入，保证 stamp ≥ 目录 mtime。

**实测**：按此流程装完，连续 3 次启动均 1 秒就绪，user dir mtime 与 `last_build_time` 相等且不再变化。

## 构建机上重新生成词库产物

```sh
# 构建机 boangs@192.168.64.4
git clone https://github.com/gaboolic/rime-frost /tmp/rime-frost
/path/to/rmkit-cn/tools/build-librime/build-dict.sh /tmp/rime-frost /tmp/rime-dist
# → /tmp/rime-dist/rime-runtime-data.tar.gz
# → /tmp/rime-dist/rime-prebuilt.tar.gz
```

脚本会先编一份 **host 版 librime**（只为拿 `rime_deployer` 工具，跟 `build.sh` 交叉编译出的设备版互不干扰），然后：

```sh
rime_deployer --build <user_data_dir> <shared_data_dir>
# 产物落在 <user_data_dir>/build/  ——参数顺序是 user 在前, 写反会把 build/ 拉进源码树
```

编译耗时约 3 分钟（构建机 x86_64）。

## 已确认的事实

- **x86_64 编译的产物可直接在 aarch64 设备上用。** rime 的 `.table.bin`/`.prism.bin`/`.reverse.bin` 用 `OffsetPtr<T, int32_t>` 偏移量寻址，不含原生指针，格式与字长无关。实测：构建机 x86_64 编出的 `build/` 推到 rmpp (aarch64) 热启动 1 秒，`nihao` → `你好/拟好/妳好/逆号`，`jianaifeigong` → `兼爱非攻`。同理适用于 rm2 (armv7l)，但尚未在真机验证过。
- **必须避免设备端编译。** 设备冷编译实测 110 秒、峰值 `RssAnon` 881 MB，且编译完堆不归还 OS，进程会一直占着 467 MB。用预编译产物则是 1 秒 / 稳态 `RssAnon` 12.9 MB / `RssFile` 26.7 MB / `VmRSS` 39.6 MB。rm2 的 1 GB 内存扛不住前者，但后者绰绰有余。
- **没编任何 librime 插件**，所以下面这些是废重量，已从包里剔除：
  - `zh-moqi.gram` (7 MB)：`rime_frost.schema.yaml` 里的 `grammar:` 段需要 librime-octagram。`poet.cc` 的 `Grammar::Require("grammar")` 找不到组件返回 `nullptr`，整个语言模型静默不生效。
  - `lua/`：所有 `lua_translator@*` / `lua_filter@*` 需要 librime-lua，组件创建失败被跳过。
  - `cn_dicts/tencent.dict.yaml` (11 MB)：在 `import_tables` 里本来就是注释掉的。
  - `essay.txt` (5.7 MB)：已无引用。

  若日后补编 octagram / lua 插件，需要把对应文件重新加回 `build-dict.sh` 的 `stage_source`，并重出两个包。
- **`cn_dicts_cell/` 保留**（43 MB 源码，编进 `build/`）。实测有效：`jianaifeigong` → `兼爱非攻`（去掉则退化成 `简爱费工`）、`liangjiapeihe` → `量价配合`（去掉则是 `两家配合`）。
- **验证候选质量要走 `/rime/input`**，不能用 `/candidates?pinyin=`——后者走的是旧的自研 Go 引擎，不经过 librime。喂词的方式是把拼音写进 `/tmp/rmkit_char_queue` 再 GET `/rime/input`。
