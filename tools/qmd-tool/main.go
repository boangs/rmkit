// qmd-tool: tools/hash-qmd.py + tools/qmd_hash_check.py 的 Go 重写.
//
// 两个用法 (注意: Go flag 库要求 flag 在 positional 参数之前):
//
//	qmd-tool hash [-hashtab <path>] <src.qmd>
//	    把 qmd-src/*.qmd 编译成 dist/*.qmd, 即把 identifier 替换为
//	    hashtab 里对应的 u64 hash 形式. 输出到 stdout.
//	    -hashtab 默认 ./tools/hashtab (跟 PC install.sh 同步设备 hashtab 后的位置);
//	    设备端 OTA 时改成 /home/root/xovi/exthome/qt-resource-rebuilder/hashtab.
//
//	qmd-tool check [-hashtabs <dir>] [-qmd <dir>]
//	    扫 <qmd> 下所有 *.qmd, 校验 hash 都在 <hashtabs>/hashtab-* 任一文件并集中.
//	    -hashtabs 默认 ./tools/hashtabs, -qmd 默认 ./qmd.
//	    退出码: 0 全部命中; 1 有孤儿 hash; 2 环境/路径问题.
//
// 此二进制无外部依赖 (纯标准库), 跨平台 cross-compile, 同时给 PC install.sh
// 和设备端 OTA 客户端使用. 替代了原来的 Python 脚本, 设备从此 0 Python 依赖.
package main

import (
	"flag"
	"fmt"
	"os"
)

func usage() {
	fmt.Fprintln(os.Stderr, "用法 (flag 必须在 positional 之前):")
	fmt.Fprintln(os.Stderr, "  qmd-tool hash  [-hashtab <path>] <src.qmd>")
	fmt.Fprintln(os.Stderr, "  qmd-tool check [-hashtabs <dir>] [-qmd <dir>]")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "hash":
		runHash(os.Args[2:])
	case "check":
		runCheck(os.Args[2:])
	case "-h", "--help":
		usage()
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "未知子命令: %s\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func runHash(args []string) {
	fs := flag.NewFlagSet("hash", flag.ExitOnError)
	hashtab := fs.String("hashtab", "tools/hashtab", "hashtab 文件路径")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "用法: qmd-tool hash [-hashtab <path>] <src.qmd>")
		os.Exit(2)
	}
	src := fs.Arg(0)
	table, err := loadHashtab(*hashtab)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	data, err := os.ReadFile(src)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	out := compileQMD(string(data), table)
	if _, err := os.Stdout.WriteString(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func runCheck(args []string) {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	hashtabs := fs.String("hashtabs", "tools/hashtabs", "hashtabs 目录 (含 hashtab-* 快照)")
	qmd := fs.String("qmd", "qmd", "qmd 目录")
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
	bad, err := checkQMD(*hashtabs, *qmd)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if bad > 0 {
		os.Exit(1)
	}
}
