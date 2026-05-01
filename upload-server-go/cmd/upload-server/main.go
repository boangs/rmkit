package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/rmkit-cn/upload-server/internal/server"
)

func main() {
	var (
		listen         = flag.String("listen", ":8080", "监听地址")
		staticDir      = flag.String("static", "", "静态资源目录 (默认: <二进制所在目录>/static)")
		fontsDir       = flag.String("fonts", "", "字体存放目录 (默认: $HOME/.local/share/rmkit-cn/fonts)")
		screensDir     = flag.String("screens", "", "锁屏图存放目录 (默认: $HOME/.local/share/rmkit-cn/screens)")
		stagingDir     = flag.String("staging", "/tmp/rmkit_upload", "文档上传暂存目录")
		fontsActiveDir = flag.String("fonts-active", "", "字体激活符号链接目录 (默认: $HOME/.local/share/fonts)")
		xochitlConf    = flag.String("xochitl-conf", "", "xochitl 配置路径 (默认: $HOME/.config/remarkable/xochitl.conf)")
	)
	flag.Parse()

	if *staticDir == "" {
		exe, err := os.Executable()
		if err != nil {
			log.Fatalf("os.Executable: %v", err)
		}
		*staticDir = filepath.Join(filepath.Dir(exe), "static")
	}

	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("home dir: %v", err)
	}
	if *fontsDir == "" {
		*fontsDir = filepath.Join(home, ".local/share/rmkit-cn/fonts")
	}
	if *screensDir == "" {
		*screensDir = filepath.Join(home, ".local/share/rmkit-cn/screens")
	}
	if *fontsActiveDir == "" {
		*fontsActiveDir = filepath.Join(home, ".local/share/fonts")
	}
	if *xochitlConf == "" {
		*xochitlConf = filepath.Join(home, ".config/remarkable/xochitl.conf")
	}

	srv, err := server.New(server.Config{
		StaticDir:      *staticDir,
		FontsDir:       *fontsDir,
		ScreensDir:     *screensDir,
		DocStagingDir:  *stagingDir,
		FontsActiveDir: *fontsActiveDir,
		XochitlConf:    *xochitlConf,
	})
	if err != nil {
		log.Fatalf("server.New: %v", err)
	}

	fmt.Printf("rmkit-cn upload-server listening on %s\n", *listen)
	fmt.Printf("  static = %s\n  fonts  = %s\n  screens = %s\n  staging = %s\n  fonts-active = %s\n  xochitl-conf = %s\n",
		*staticDir, *fontsDir, *screensDir, *stagingDir, *fontsActiveDir, *xochitlConf)

	if err := http.ListenAndServe(*listen, srv.Routes()); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
