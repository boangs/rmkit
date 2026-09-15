package space

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManifestValidate(t *testing.T) {
	good := `{"id":"gomoku","name":"五子棋","version":"1.0.0","entry":"main.qml","icon":"icon.svg","category":"game"}`
	if _, err := ParseManifest([]byte(good)); err != nil {
		t.Fatalf("合法清单被拒: %v", err)
	}
	bad := map[string]string{
		"id 大写":     `{"id":"Gomoku","name":"x","version":"1","entry":"main.qml"}`,
		"缺 entry":   `{"id":"a","name":"x","version":"1"}`,
		"entry 穿越":  `{"id":"a","name":"x","version":"1","entry":"../main.qml"}`,
		"category":  `{"id":"a","name":"x","version":"1","entry":"m.qml","category":"weird"}`,
		"launch 类型": `{"id":"a","name":"x","version":"1","launch":{"type":"exec"}}`,
		"port":      `{"id":"a","name":"x","version":"1","entry":"m.qml","service":{"exec":"bin/s","port":80}}`,
		"min_shell": `{"id":"a","name":"x","version":"1","entry":"m.qml","min_shell":99}`,
	}
	for name, src := range bad {
		if _, err := ParseManifest([]byte(src)); err == nil {
			t.Errorf("%s: 应该被拒", name)
		}
	}
}

func writeApp(t *testing.T, root, id, manifest string) {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ManifestName), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(dir, "main.qml"), []byte("import QtQuick\nItem {}\n"), 0o644)
}

func TestRegistryListOrderAndOverride(t *testing.T) {
	tmp := t.TempDir()
	r := &Registry{BuiltinDir: filepath.Join(tmp, "b"), UserDir: filepath.Join(tmp, "u"), DataDir: filepath.Join(tmp, "d"), Arch: "aarch64"}
	writeApp(t, r.BuiltinDir, "gomoku", `{"id":"gomoku","name":"五子棋","version":"1.0","entry":"main.qml","category":"game"}`)
	writeApp(t, r.BuiltinDir, "settings", `{"id":"settings","name":"设置","version":"1.0","entry":"main.qml","category":"settings"}`)
	writeApp(t, r.BuiltinDir, "broken", `{"id":"broken"}`)
	writeApp(t, r.BuiltinDir, "armonly", `{"id":"armonly","name":"x","version":"1","entry":"main.qml","arch":["armv7"]}`)
	writeApp(t, r.UserDir, "gomoku", `{"id":"gomoku","name":"五子棋 Pro","version":"2.0","entry":"main.qml","category":"game","service":{"exec":"bin/s","port":9001}}`)

	apps := r.List()
	if len(apps) != 4 {
		t.Fatalf("应有 4 条, 得到 %d", len(apps))
	}
	if apps[0].ID != "settings" {
		t.Errorf("settings 类应排最前, 实际 %s", apps[0].ID)
	}
	g, ok := r.Get("gomoku")
	if !ok || g.Builtin || g.Version != "2.0" {
		t.Errorf("用户目录应覆盖内置: %+v", g)
	}
	if g.ServiceURL != "http://127.0.0.1:9001" || !strings.HasPrefix(g.EntryURL, "file://") {
		t.Errorf("URL 解析不对: %+v", g)
	}
	if b, _ := r.Get("broken"); b.Error == "" {
		t.Error("坏清单应带 Error")
	}
	if a, _ := r.Get("armonly"); a.Error == "" {
		t.Error("架构不符应带 Error")
	}
}

func makeZip(t *testing.T, files map[string]string) *zip.Reader {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = w.Write([]byte(content))
	}
	_ = zw.Close()
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	return zr
}

func TestInstallZipAndUninstall(t *testing.T) {
	tmp := t.TempDir()
	r := &Registry{BuiltinDir: filepath.Join(tmp, "b"), UserDir: filepath.Join(tmp, "u"), DataDir: filepath.Join(tmp, "d"), Arch: "aarch64"}
	writeApp(t, r.BuiltinDir, "gomoku", `{"id":"gomoku","name":"五子棋","version":"1.0","entry":"main.qml"}`)

	// 顶级目录包装的 zip (GitHub 打包风格)
	zr := makeZip(t, map[string]string{
		"music-1.0/manifest.json": `{"id":"music","name":"音乐","version":"1.0","entry":"main.qml","service":{"exec":"bin/server","port":9100}}`,
		"music-1.0/main.qml":      "import QtQuick\nItem {}\n",
		"music-1.0/bin/server":    "#!/bin/sh\n",
	})
	app, err := r.InstallZip(zr, nil)
	if err != nil {
		t.Fatalf("安装失败: %v", err)
	}
	if app.Builtin || app.Dir != filepath.Join(r.UserDir, "music") {
		t.Errorf("安装位置不对: %+v", app)
	}
	if info, err := os.Stat(filepath.Join(app.Dir, "bin", "server")); err != nil || info.Mode()&0o111 == 0 {
		t.Errorf("bin/ 下文件应可执行: %v", err)
	}
	if _, err := os.Stat(filepath.Join(r.UserDir, ".tmp-music")); err == nil {
		t.Error("临时目录没清")
	}

	// 路径穿越必须拒绝
	evil := makeZip(t, map[string]string{
		"manifest.json": `{"id":"evil","name":"x","version":"1","entry":"main.qml"}`,
		"../../pwn":     "x",
	})
	if _, err := r.InstallZip(evil, nil); err == nil {
		t.Error("路径穿越 zip 应被拒")
	}
	if _, err := os.Stat(filepath.Join(r.UserDir, "evil")); err == nil {
		t.Error("失败的安装不应留下目录")
	}

	// 内置不可卸载, 用户应用可卸载
	if err := r.Uninstall("gomoku", nil); err == nil {
		t.Error("内置应用应拒绝卸载")
	}
	if err := r.Uninstall("music", nil); err != nil {
		t.Errorf("卸载失败: %v", err)
	}
	if _, ok := r.Get("music"); ok {
		t.Error("卸载后仍在列表")
	}
}

func TestSupervisorStartStop(t *testing.T) {
	tmp := t.TempDir()
	dir := filepath.Join(tmp, "apps", "echo")
	_ = os.MkdirAll(filepath.Join(dir, "bin"), 0o755)
	script := "#!/bin/sh\necho started $SPACE_APP_ID\nwhile true; do sleep 1; done\n"
	if err := os.WriteFile(filepath.Join(dir, "bin", "run"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	app := App{Manifest: Manifest{ID: "echo", Service: &Service{Exec: "bin/run"}}, Dir: dir, DataDir: filepath.Join(tmp, "data", "echo")}
	sup := NewSupervisor("http://127.0.0.1:8080")
	st, err := sup.Start(app)
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	if !st.Running || st.PID == 0 {
		t.Fatalf("状态不对: %+v", st)
	}
	if err := sup.Stop("echo"); err != nil {
		t.Fatalf("停止失败: %v", err)
	}
	if sup.Status("echo").Running {
		t.Error("停止后仍 running")
	}
	b, _ := os.ReadFile(filepath.Join(app.DataDir, "service.log"))
	if !strings.Contains(string(b), "started echo") {
		t.Errorf("日志没写到数据目录: %q", b)
	}
}

func TestDataGetPut(t *testing.T) {
	tmp := t.TempDir()
	h := New(filepath.Join(tmp, "b"), filepath.Join(tmp, "u"), filepath.Join(tmp, "d"), "aarch64", "")
	mux := http.NewServeMux()
	h.Mount(mux)
	do := func(method, path, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
		return rec
	}
	if rec := do("GET", "/space/apps/weather/data/last", ""); rec.Code != 404 {
		t.Errorf("未写入应 404, 得到 %d", rec.Code)
	}
	if rec := do("PUT", "/space/apps/weather/data/last", `{"temp": 24}`); rec.Code != 200 {
		t.Fatalf("写入失败 %d %s", rec.Code, rec.Body.String())
	}
	if rec := do("GET", "/space/apps/weather/data/last", ""); rec.Code != 200 || !strings.Contains(rec.Body.String(), "24") {
		t.Errorf("读回不对 %d %s", rec.Code, rec.Body.String())
	}
	if rec := do("PUT", "/space/apps/weather/data/last", `not json`); rec.Code != 400 {
		t.Errorf("非 JSON 应 400, 得到 %d", rec.Code)
	}
	if rec := do("PUT", "/space/apps/weather/data/..%2Fx", `{}`); rec.Code == 200 {
		t.Errorf("路径穿越 key 不应成功")
	}
	if _, err := os.Stat(filepath.Join(tmp, "d", "weather", "last.json")); err != nil {
		t.Errorf("文件没落在数据目录: %v", err)
	}
}
