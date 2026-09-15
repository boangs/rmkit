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
		spaceDir       = flag.String("space", "/home/root/rmkit-cn/space", "「空间」内置应用目录 (含 shell/ kit/ apps/)")
		spaceUserDir   = flag.String("space-apps", "", "「空间」用户应用目录 (默认: $HOME/.local/share/rmkit-cn/space/apps)")
		spaceDataDir   = flag.String("space-data", "", "「空间」应用数据目录 (默认: $HOME/.local/share/rmkit-cn/space/data)")
		spaceStore     = flag.String("space-store", "https://boangs.com/rmkit-space/index.json", "「空间」应用商店索引 URL (空 = 关闭商店)")
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
	if *spaceUserDir == "" {
		*spaceUserDir = filepath.Join(home, ".local/share/rmkit-cn/space/apps")
	}
	if *spaceDataDir == "" {
		*spaceDataDir = filepath.Join(home, ".local/share/rmkit-cn/space/data")
	}

	srv, err := server.New(server.Config{
		StaticDir:      *staticDir,
		FontsDir:       *fontsDir,
		ScreensDir:     *screensDir,
		DocStagingDir:  *stagingDir,
		FontsActiveDir: *fontsActiveDir,
		XochitlConf:    *xochitlConf,
		SpaceDir:       *spaceDir,
		SpaceUserDir:   *spaceUserDir,
		SpaceDataDir:   *spaceDataDir,
		SpaceBaseURL:   "http://127.0.0.1:8080",
		SpaceStore:     *spaceStore,
	})
	if err != nil {
		log.Fatalf("server.New: %v", err)
	}
	server.StartAudioDaemon() // 蓝牙音频 (装了 rmkit-audio 才生效)
	srv.Space().AutoStart()   // 「空间」里声明了 autostart 的应用后台

	fmt.Printf("rmkit-cn upload-server listening on %s\n", *listen)
	fmt.Printf("  static = %s\n  fonts  = %s\n  screens = %s\n  staging = %s\n  fonts-active = %s\n  xochitl-conf = %s\n",
		*staticDir, *fontsDir, *screensDir, *stagingDir, *fontsActiveDir, *xochitlConf)

	if err := http.ListenAndServe(*listen, srv.Routes()); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
