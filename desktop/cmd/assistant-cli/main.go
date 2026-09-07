// assistant-cli 是桌面助手内核层的命令行入口, 用来在没有 GUI 的环境 (CI / 远程排障)
// 走一遍与 GUI 完全相同的探测 → 计划 → 执行流程。
//
//	assistant-cli -host 10.11.99.1 -password xxx probe
//	assistant-cli ... -bundle rmkit-cn-bundle.zip plan-rmkit | run-rmkit | uninstall-rmkit
//	assistant-cli ... -bundle android-rmppm-bundle.zip plan-android | run-android | uninstall-android
//	assistant-cli ... boot-android | return-stock
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"

	"github.com/rmkit-cn/desktop/internal/android"
	"github.com/rmkit-cn/desktop/internal/bundle"
	"github.com/rmkit-cn/desktop/internal/probe"
	"github.com/rmkit-cn/desktop/internal/rmkit"
	"github.com/rmkit-cn/desktop/internal/sshx"
)

func main() {
	host := flag.String("host", "10.11.99.1", "设备地址")
	password := flag.String("password", os.Getenv("RM_PASSWORD"), "SSH 密码 (或环境变量 RM_PASSWORD)")
	bpath := flag.String("bundle", "", "载荷包 zip")
	replace := flag.Bool("replace-system", false, "android: 覆盖已有 Android 系统")
	removeData := flag.Bool("remove-data", false, "uninstall-android: 连同 /home 数据删除")
	flag.Parse()
	cmd := flag.Arg(0)
	if cmd == "" {
		flag.Usage()
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	log := func(s string) { fmt.Println(s) }

	c, err := sshx.Dial(ctx, *host, *password, log)
	die(err)
	defer c.Close()
	info, err := probe.Run(ctx, c)
	die(err)

	var b *bundle.Bundle
	if *bpath != "" {
		b, err = bundle.Open(*bpath, true)
		die(err)
		defer b.Close()
		fmt.Printf("载荷包: %s 版本 %s, %d 个文件\n", b.Manifest.Component, b.Manifest.Version, len(b.Manifest.Files))
	}
	need := func() {
		if b == nil {
			die(fmt.Errorf("%s 需要 -bundle", cmd))
		}
	}
	switch cmd {
	case "probe":
		dump(info)
	case "plan-rmkit":
		need()
		p, err := rmkit.NewPlan(info, b)
		die(err)
		dump(p)
	case "run-rmkit":
		need()
		p, err := rmkit.NewPlan(info, b)
		die(err)
		die(rmkit.Run(ctx, c, b, p, log))
	case "uninstall-rmkit":
		die(rmkit.Uninstall(ctx, c))
	case "plan-android", "run-android":
		need()
		res, err := c.Run(ctx, "[ -e /home/root/android-system/system/bin/init ] && echo yes || echo no")
		die(err)
		p, err := android.NewPlan(info, b, res.Stdout == "yes\n", *replace)
		die(err)
		if cmd == "plan-android" {
			dump(p)
			return
		}
		die(android.Run(ctx, c, b, p, log))
	case "uninstall-android":
		die(android.Uninstall(ctx, c, *removeData))
	case "boot-android":
		die(android.BootAndroid(ctx, c))
	case "return-stock":
		die(android.ReturnToStock(ctx, c))
	default:
		die(fmt.Errorf("未知命令 %s", cmd))
	}
}

func dump(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func die(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "✗", err)
		os.Exit(1)
	}
}
