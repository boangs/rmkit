// Package bundle 定义桌面助手的载荷包: 一个 zip (可随机访问, 大文件不必整包读入内存),
// 根目录有 manifest.json 记录版本、组件与每个文件的 sha256。
//
// 包由 cmd/mkbundle 从仓库产物生成, 发布为 GitHub Release 附件; 用户也可以选本地文件。
// 助手打开包时先校验 manifest 里每个条目的 sha256 再使用, 篡改/下载不完整都会被拒绝。
package bundle

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
)

// ManifestName 是包内清单文件名。
const ManifestName = "manifest.json"

// Component 标识包里装的是什么。
type Component string

const (
	ComponentRmkit   Component = "rmkit-cn"
	ComponentAndroid Component = "android-rmppm"
)

// Entry 是清单里一个文件。
type Entry struct {
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Manifest 是包清单。
type Manifest struct {
	Component Component        `json:"component"`
	Version   string           `json:"version"` // 如 git 短 hash + 日期
	Created   string           `json:"created"`
	Notes     string           `json:"notes,omitempty"`
	Files     map[string]Entry `json:"files"`
}

// Bundle 是打开的载荷包。
type Bundle struct {
	Path     string
	Manifest Manifest
	zr       *zip.ReadCloser
	index    map[string]*zip.File
}

// Open 打开并校验载荷包。verify=true 时逐文件算 sha256 (首次打开建议开, 之后可关)。
func Open(path string, verify bool) (*Bundle, error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, fmt.Errorf("打不开载荷包 %s: %w", path, err)
	}
	b := &Bundle{Path: path, zr: zr, index: map[string]*zip.File{}}
	for _, f := range zr.File {
		b.index[f.Name] = f
	}
	mf, ok := b.index[ManifestName]
	if !ok {
		_ = zr.Close()
		return nil, errors.New("载荷包缺 manifest.json, 不是 rmkit 桌面助手的包")
	}
	rc, err := mf.Open()
	if err != nil {
		_ = zr.Close()
		return nil, err
	}
	err = json.NewDecoder(rc).Decode(&b.Manifest)
	_ = rc.Close()
	if err != nil {
		_ = zr.Close()
		return nil, fmt.Errorf("manifest.json 解析失败: %w", err)
	}
	for name := range b.Manifest.Files {
		if _, ok := b.index[name]; !ok {
			_ = zr.Close()
			return nil, fmt.Errorf("载荷包缺文件 %s (清单有, 包里没有)", name)
		}
	}
	if verify {
		if err := b.Verify(); err != nil {
			_ = zr.Close()
			return nil, err
		}
	}
	return b, nil
}

// Close 关闭包。
func (b *Bundle) Close() error { return b.zr.Close() }

// Has 报告包里是否有该文件。
func (b *Bundle) Has(name string) bool {
	_, ok := b.Manifest.Files[name]
	return ok
}

// Names 返回清单里的文件名 (排序)。
func (b *Bundle) Names() []string {
	names := make([]string, 0, len(b.Manifest.Files))
	for n := range b.Manifest.Files {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Open 打开包内一个文件的读取流。
func (b *Bundle) Open(name string) (io.ReadCloser, error) {
	f, ok := b.index[name]
	if !ok {
		return nil, fmt.Errorf("载荷包没有 %s", name)
	}
	return f.Open()
}

// ReadAll 读出一个小文件的全部内容。
func (b *Bundle) ReadAll(name string) ([]byte, error) {
	rc, err := b.Open(name)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// Size 返回清单记录的大小。
func (b *Bundle) Size(name string) int64 { return b.Manifest.Files[name].Size }

// Verify 逐文件校验 sha256。
func (b *Bundle) Verify() error {
	for name, e := range b.Manifest.Files {
		rc, err := b.Open(name)
		if err != nil {
			return err
		}
		h := sha256.New()
		n, err := io.Copy(h, rc)
		_ = rc.Close()
		if err != nil {
			return fmt.Errorf("读 %s 失败: %w", name, err)
		}
		if n != e.Size {
			return fmt.Errorf("%s 大小不符 (清单 %d, 实际 %d)", name, e.Size, n)
		}
		if got := hex.EncodeToString(h.Sum(nil)); got != e.SHA256 {
			return fmt.Errorf("%s 校验失败 (sha256 不符), 载荷包已损坏或被改动", name)
		}
	}
	return nil
}
