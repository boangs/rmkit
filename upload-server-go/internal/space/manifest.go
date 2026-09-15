// Package space 是「空间 (SPACE)」启动台的后端: 应用注册表、绿色安装/卸载、应用私有后台进程托管。
//
// 设计原则 (高内聚, 低耦合):
//   - 本包对任何具体应用一无所知, 只认应用目录里的 manifest.json。
//   - upload-server 只把本包挂到 /space/ 路径下, 不参与应用逻辑。
//   - 应用自己的后端 (如播放器) 由应用包自带, 在 manifest 里声明, 本包按需拉起/收掉,
//     应用前端直接访问自己的后端端口, 不经过 upload-server。
package space

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ShellVersion 是外壳 (Space.qml) 与本后端共同遵守的应用契约版本。
// manifest.min_shell 大于它的应用不会被加载。
const ShellVersion = 1

// ManifestName 是应用目录里清单文件的固定名字。
const ManifestName = "manifest.json"

// Service 声明应用自带的后台进程。
type Service struct {
	Exec      string   `json:"exec"`                // 相对应用目录的可执行文件, 如 bin/music-server
	Args      []string `json:"args,omitempty"`      // 附加参数
	Port      int      `json:"port,omitempty"`      // 监听端口 (>0 时外壳会等它就绪并把 serviceUrl 交给前端)
	Health    string   `json:"health,omitempty"`    // 就绪探测路径, 默认 "/"
	KeepAlive bool     `json:"keepalive,omitempty"` // 退出应用界面后是否继续跑 (后台播放等)
	AutoStart bool     `json:"autostart,omitempty"` // upload-server 启动时是否自动拉起
}

// Launch 声明"点图标即启动外部程序"的应用 (无 QML 界面), 如 KOReader / Android。
type Launch struct {
	Type    string `json:"type"`              // "post": 向 upload-server 发 POST; "appload": 走 xovi appload 单例
	Path    string `json:"path,omitempty"`    // post 的路径 (appload 时作为兜底)
	ID      string `json:"id,omitempty"`      // appload 的应用标识, 如 external::koreader
	Confirm string `json:"confirm,omitempty"` // 非空则先弹确认框 (重启类操作)
}

// Manifest 是应用清单 (manifest.json)。
type Manifest struct {
	ID          string   `json:"id"`                    // 唯一标识: 小写字母/数字/-/_ , 1-32 位, 也是目录名
	Name        string   `json:"name"`                  // 显示名 (中文)
	NameEn      string   `json:"name_en,omitempty"`     // 英文名 (可选)
	Version     string   `json:"version"`               // 语义化版本
	Description string   `json:"description,omitempty"` // 一句话说明
	Icon        string   `json:"icon,omitempty"`        // 图标: 相对路径 / 绝对路径 / qrc: 或 file: URL
	Entry       string   `json:"entry,omitempty"`       // 界面入口 QML (相对路径), 与 launch 二选一或同时有
	Widget      string   `json:"widget,omitempty"`      // 首页小组件 QML (相对路径, 可选)
	WidgetSize  string   `json:"widget_size,omitempty"` // 小组件尺寸: half (半宽, 默认) / hero (首页顶部整宽大卡)
	Category    string   `json:"category,omitempty"`    // system / settings / reader / tool / game / other
	Order       int      `json:"order,omitempty"`       // 同类内排序 (小的在前)
	Arch        []string `json:"arch,omitempty"`        // 支持的架构: aarch64 / armv7; 空 = 都支持
	MinShell    int      `json:"min_shell,omitempty"`   // 需要的最低外壳契约版本
	Service     *Service `json:"service,omitempty"`
	Launch      *Launch  `json:"launch,omitempty"`
}

var idRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

var categoryOrder = map[string]int{
	"system": 0, "settings": 1, "reader": 2, "tool": 3, "game": 4, "other": 5,
}

// Validate 检查清单是否自洽; 出错信息面向应用开发者。
func (m *Manifest) Validate() error {
	if !idRe.MatchString(m.ID) {
		return fmt.Errorf("id %q 不合法 (小写字母/数字/-/_, 1-32 位, 首字符须为字母或数字)", m.ID)
	}
	if strings.TrimSpace(m.Name) == "" {
		return errors.New("name 不能为空")
	}
	if strings.TrimSpace(m.Version) == "" {
		return errors.New("version 不能为空")
	}
	if m.Entry == "" && m.Launch == nil {
		return errors.New("entry (界面 QML) 与 launch (外部启动) 至少要有一个")
	}
	for _, f := range []struct{ name, val string }{{"entry", m.Entry}, {"widget", m.Widget}} {
		if f.val != "" && !isRelativeInside(f.val) {
			return fmt.Errorf("%s 必须是应用目录内的相对路径: %q", f.name, f.val)
		}
	}
	if m.Icon != "" && !isURL(m.Icon) && !filepath.IsAbs(m.Icon) && !isRelativeInside(m.Icon) {
		return fmt.Errorf("icon 必须是相对路径、绝对路径或 qrc:/file: URL: %q", m.Icon)
	}
	if m.Category == "" {
		m.Category = "tool"
	}
	if m.Widget != "" && m.WidgetSize == "" {
		m.WidgetSize = "half"
	}
	if m.WidgetSize != "" && m.WidgetSize != "half" && m.WidgetSize != "hero" {
		return fmt.Errorf("widget_size %q 不认识 (half / hero)", m.WidgetSize)
	}
	if _, ok := categoryOrder[m.Category]; !ok {
		return fmt.Errorf("category %q 不认识 (system/settings/reader/tool/game/other)", m.Category)
	}
	if m.MinShell > ShellVersion {
		return fmt.Errorf("需要外壳契约版本 %d, 本机只有 %d", m.MinShell, ShellVersion)
	}
	for _, a := range m.Arch {
		if a != "aarch64" && a != "armv7" {
			return fmt.Errorf("arch %q 不认识 (aarch64 / armv7)", a)
		}
	}
	if s := m.Service; s != nil {
		if !isRelativeInside(s.Exec) {
			return fmt.Errorf("service.exec 必须是应用目录内的相对路径: %q", s.Exec)
		}
		if s.Port != 0 && (s.Port < 1024 || s.Port > 65535) {
			return fmt.Errorf("service.port %d 超出 1024-65535", s.Port)
		}
		if s.Health != "" && !strings.HasPrefix(s.Health, "/") {
			return fmt.Errorf("service.health 必须以 / 开头: %q", s.Health)
		}
	}
	if l := m.Launch; l != nil {
		switch l.Type {
		case "post":
			if !strings.HasPrefix(l.Path, "/") {
				return fmt.Errorf("launch.path 必须以 / 开头: %q", l.Path)
			}
		case "appload":
			if l.ID == "" {
				return errors.New("launch.type=appload 需要 launch.id")
			}
			if l.Path != "" && !strings.HasPrefix(l.Path, "/") {
				return fmt.Errorf("launch.path 必须以 / 开头: %q", l.Path)
			}
		default:
			return fmt.Errorf("launch.type %q 不认识 (post / appload)", l.Type)
		}
	}
	return nil
}

// SupportsArch 判断清单是否支持给定架构 (空 = 全支持)。
func (m *Manifest) SupportsArch(arch string) bool {
	if len(m.Arch) == 0 {
		return true
	}
	for _, a := range m.Arch {
		if a == arch {
			return true
		}
	}
	return false
}

// LoadManifest 读取并校验 dir/manifest.json。
func LoadManifest(dir string) (*Manifest, error) {
	b, err := os.ReadFile(filepath.Join(dir, ManifestName))
	if err != nil {
		return nil, err
	}
	return ParseManifest(b)
}

// ParseManifest 解析并校验清单内容。
func ParseManifest(b []byte) (*Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("manifest.json 不是合法 JSON: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return &m, nil
}

// isRelativeInside: 相对路径, 不含 .., 不是绝对路径, 不是 URL。
func isRelativeInside(p string) bool {
	if p == "" || filepath.IsAbs(p) || isURL(p) {
		return false
	}
	clean := filepath.Clean(p)
	return clean != "." && !strings.HasPrefix(clean, "..")
}

func isURL(p string) bool {
	return strings.HasPrefix(p, "qrc:") || strings.HasPrefix(p, "file:")
}
