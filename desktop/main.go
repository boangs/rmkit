// rmkit 助手: 在 Mac/Windows 上通过 USB 直连 reMarkable, 检测机型/固件后安全地安装
// rmkit-cn (中文化/输入法/高级面板) 或 RMPPM 单槽 Android。
//
// 隐私原则: 没有服务器, 没有遥测; 只连用户给的地址; 只读系统信息, 不碰用户文档;
// 每条远端命令和写入的文件都记在本机审计日志里。
package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()
	err := wails.Run(&options.App{
		Title:            "rmkit 助手",
		Width:            980,
		Height:           760,
		MinWidth:         820,
		MinHeight:        600,
		AssetServer:      &assetserver.Options{Assets: assets},
		BackgroundColour: &options.RGBA{R: 250, G: 250, B: 248, A: 1},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		Bind:             []interface{}{app},
	})
	if err != nil {
		println("Error:", err.Error())
	}
}
