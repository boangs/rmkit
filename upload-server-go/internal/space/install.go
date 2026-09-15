package space

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// 单个应用包解压上限, 防止畸形 zip 撑爆 /home。
const maxAppBytes = 256 << 20

// InstallZip 把一个应用包 (zip) 绿色安装到用户应用目录。
// 包结构: manifest.json 在 zip 根, 或者在唯一的一层顶级目录下 (GitHub 打包常见)。
// 流程: 校验清单 → 解压到临时目录 → 停掉同名后台 → 原子替换目录。失败不影响已装版本。
func (r *Registry) InstallZip(zr *zip.Reader, sup *Supervisor) (App, error) {
	prefix, m, err := findManifest(zr)
	if err != nil {
		return App{}, err
	}
	if !m.SupportsArch(r.Arch) {
		return App{}, fmt.Errorf("应用 %s 不支持本机架构 %s", m.ID, r.Arch)
	}
	if err := os.MkdirAll(r.UserDir, 0o755); err != nil {
		return App{}, err
	}
	tmp := filepath.Join(r.UserDir, ".tmp-"+m.ID)
	_ = os.RemoveAll(tmp)
	if err := extract(zr, prefix, tmp); err != nil {
		_ = os.RemoveAll(tmp)
		return App{}, err
	}
	final := filepath.Join(r.UserDir, m.ID)
	if sup != nil {
		_ = sup.Stop(m.ID)
	}
	_ = os.RemoveAll(final)
	if err := os.Rename(tmp, final); err != nil {
		_ = os.RemoveAll(tmp)
		return App{}, err
	}
	a, ok := r.Get(m.ID)
	if !ok {
		return App{}, errors.New("安装后在注册表里找不到应用 (目录扫描失败)")
	}
	return a, nil
}

// InstallFromURL 下载应用包再安装; sha256hex 非空时校验摘要。
func (r *Registry) InstallFromURL(url, sha256hex string, sup *Supervisor) (App, error) {
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return App{}, fmt.Errorf("下载失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return App{}, fmt.Errorf("下载失败: HTTP %d", resp.StatusCode)
	}
	tmp, err := os.CreateTemp("", "space-app-*.zip")
	if err != nil {
		return App{}, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(resp.Body, maxAppBytes+1))
	if err != nil {
		return App{}, fmt.Errorf("下载失败: %w", err)
	}
	if n > maxAppBytes {
		return App{}, errors.New("应用包超过 256MB")
	}
	if sha256hex != "" && !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), sha256hex) {
		return App{}, errors.New("应用包 sha256 校验不通过")
	}
	zr, err := zip.NewReader(tmp, n)
	if err != nil {
		return App{}, fmt.Errorf("不是合法 zip: %w", err)
	}
	return r.InstallZip(zr, sup)
}

// Uninstall 删除用户目录里的应用 (内置应用不可卸载; 应用数据目录保留)。
func (r *Registry) Uninstall(id string, sup *Supervisor) error {
	if !idRe.MatchString(id) {
		return errors.New("id 不合法")
	}
	dir := filepath.Join(r.UserDir, id)
	if _, err := os.Stat(filepath.Join(dir, ManifestName)); err != nil {
		if _, e := os.Stat(filepath.Join(r.BuiltinDir, id, ManifestName)); e == nil {
			return errors.New("内置应用不能卸载 (随 rmkit-cn 一起管理)")
		}
		return errors.New("没有这个应用")
	}
	if sup != nil {
		_ = sup.Stop(id)
	}
	return os.RemoveAll(dir)
}

// findManifest 在 zip 里定位 manifest.json, 返回它所在的前缀 ("" 或 "dir/") 和解析结果。
func findManifest(zr *zip.Reader) (string, *Manifest, error) {
	var root, nested *zip.File
	nestedPrefix := ""
	for _, f := range zr.File {
		name := path.Clean(f.Name)
		if name == ManifestName {
			root = f
			break
		}
		if parts := strings.Split(name, "/"); len(parts) == 2 && parts[1] == ManifestName {
			if nested != nil && nestedPrefix != parts[0]+"/" {
				return "", nil, errors.New("zip 里有多个顶级目录都带 manifest.json, 不知道装哪个")
			}
			nested, nestedPrefix = f, parts[0]+"/"
		}
	}
	f, prefix := root, ""
	if f == nil {
		f, prefix = nested, nestedPrefix
	}
	if f == nil {
		return "", nil, errors.New("zip 里找不到 manifest.json (须在根或唯一顶级目录下)")
	}
	rc, err := f.Open()
	if err != nil {
		return "", nil, err
	}
	defer rc.Close()
	b, err := io.ReadAll(io.LimitReader(rc, 1<<20))
	if err != nil {
		return "", nil, err
	}
	m, err := ParseManifest(b)
	if err != nil {
		return "", nil, err
	}
	return prefix, m, nil
}

// extract 把 prefix 下的条目解到 dst, 拒绝路径穿越, 限制总大小, 保留可执行位。
func extract(zr *zip.Reader, prefix, dst string) error {
	var total int64
	for _, f := range zr.File {
		if !strings.HasPrefix(f.Name, prefix) {
			continue
		}
		rel := strings.TrimPrefix(f.Name, prefix)
		if rel == "" {
			continue
		}
		clean := path.Clean(rel)
		if path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
			return fmt.Errorf("zip 条目路径不安全: %q", f.Name)
		}
		target := filepath.Join(dst, filepath.FromSlash(clean))
		if f.FileInfo().IsDir() || strings.HasSuffix(f.Name, "/") {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if f.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("zip 里不允许符号链接: %q", f.Name)
		}
		total += int64(f.UncompressedSize64)
		if total > maxAppBytes {
			return errors.New("应用包解压后超过 256MB")
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if f.Mode()&0o111 != 0 || strings.HasPrefix(clean, "bin/") {
			mode = 0o755
		}
		if err := writeEntry(f, target, mode); err != nil {
			return err
		}
	}
	return nil
}

func writeEntry(f *zip.File, target string, mode os.FileMode) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, io.LimitReader(rc, maxAppBytes))
	return err
}
