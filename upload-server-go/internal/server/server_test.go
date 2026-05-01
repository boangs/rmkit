package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rmkit-cn/upload-server/internal/librarian"
)

func newTestServer(t *testing.T) (*Server, http.Handler, string) {
	t.Helper()
	root := t.TempDir()
	cfg := Config{
		StaticDir:     filepath.Join(root, "static"),
		FontsDir:      filepath.Join(root, "fonts"),
		ScreensDir:    filepath.Join(root, "screens"),
		DocStagingDir: filepath.Join(root, "staging"),
	}
	if err := os.MkdirAll(cfg.StaticDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg.StaticDir, "qr.html"), []byte("上传到 reMarkable"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return srv, srv.Routes(), root
}

func multipartUpload(t *testing.T, fieldName, filename, contentType string, content []byte) (*bytes.Buffer, string) {
	t.Helper()
	body := &bytes.Buffer{}
	mw := multipart.NewWriter(body)
	h := make(map[string][]string)
	h["Content-Disposition"] = []string{`form-data; name="` + fieldName + `"; filename="` + filename + `"`}
	if contentType != "" {
		h["Content-Type"] = []string{contentType}
	}
	w, err := mw.CreatePart(h)
	if err != nil {
		t.Fatal(err)
	}
	w.Write(content)
	mw.Close()
	return body, mw.FormDataContentType()
}

func TestUploadFont(t *testing.T) {
	_, h, root := newTestServer(t)
	body, ct := multipartUpload(t, "file", "MiSans.ttf", "application/octet-stream", []byte("fake-font"))
	req := httptest.NewRequest("POST", "/fonts", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	if _, err := os.Stat(filepath.Join(root, "fonts", "MiSans.ttf")); err != nil {
		t.Fatalf("font not saved: %v", err)
	}
}

func TestListFontsEmpty(t *testing.T) {
	_, h, _ := newTestServer(t)
	req := httptest.NewRequest("GET", "/fonts", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status=%d", rr.Code)
	}
	if strings.TrimSpace(rr.Body.String()) != "[]" {
		t.Fatalf("expected [], got %q", rr.Body.String())
	}
}

func TestUploadFontPathTraversal(t *testing.T) {
	_, h, root := newTestServer(t)
	body, ct := multipartUpload(t, "file", "../evil.ttf", "", []byte("x"))
	req := httptest.NewRequest("POST", "/fonts", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	// filepath.Base 过滤后应当落在 fonts/ 内的 evil.ttf
	if _, err := os.Stat(filepath.Join(root, "fonts", "evil.ttf")); err != nil {
		t.Fatalf("expected fonts/evil.ttf to exist: %v", err)
	}
	// 不应跑到 root
	if _, err := os.Stat(filepath.Join(root, "evil.ttf")); err == nil {
		t.Fatal("path traversal escaped sandbox")
	}
}

func TestUploadFontWrongExt(t *testing.T) {
	_, h, _ := newTestServer(t)
	body, ct := multipartUpload(t, "file", "evil.exe", "", []byte("MZ"))
	req := httptest.NewRequest("POST", "/fonts", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 400 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
}

func TestDeleteFontNotFound(t *testing.T) {
	_, h, _ := newTestServer(t)
	req := httptest.NewRequest("DELETE", "/fonts/nonexistent.ttf", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 404 {
		t.Fatalf("status=%d", rr.Code)
	}
}

func TestUploadScreenWrongFormat(t *testing.T) {
	_, h, _ := newTestServer(t)
	body, ct := multipartUpload(t, "file", "x.jpg", "image/jpeg", []byte("jpg"))
	req := httptest.NewRequest("POST", "/screens", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 400 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
}

// ---- /documents (librarian pipe) ----

type fakeLibCall struct {
	signal string
	value  string
}

type fakeLibrarian struct {
	mu          sync.Mutex
	history     []fakeLibCall
	signal      atomic.Value
	value       atomic.Value
	stagedBytes atomic.Value
	response    string
	err         error
	calls       atomic.Int32
}

func (f *fakeLibrarian) invoke(signal, value string, timeout time.Duration) (string, error) {
	f.calls.Add(1)
	f.mu.Lock()
	f.history = append(f.history, fakeLibCall{signal, value})
	f.mu.Unlock()
	f.signal.Store(signal)
	f.value.Store(value)
	if b, err := os.ReadFile(value); err == nil {
		f.stagedBytes.Store(b)
	}
	return f.response, f.err
}

func withFakeLibrarian(t *testing.T, fake *fakeLibrarian) {
	t.Helper()
	prev := invokeLibrarian
	invokeLibrarian = fake.invoke
	t.Cleanup(func() { invokeLibrarian = prev })
}

func TestUploadDocumentPDF(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{response: "abc-uuid-123"}
	withFakeLibrarian(t, fake)

	body, ct := multipartUpload(t, "file", "book.pdf", "application/pdf", []byte("%PDF-1.4 fake"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != 200 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	var resp map[string]any
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp["uuid"] != "abc-uuid-123" {
		t.Errorf("expected uuid=abc-uuid-123, got %v", resp["uuid"])
	}
	if resp["name"] != "book.pdf" {
		t.Errorf("expected name=book.pdf, got %v", resp["name"])
	}
	fake.mu.Lock()
	hist := append([]fakeLibCall(nil), fake.history...)
	fake.mu.Unlock()
	if len(hist) != 2 {
		t.Fatalf("expected 2 librarian calls, got %d: %+v", len(hist), hist)
	}
	if hist[0].signal != "importDocument" {
		t.Errorf("call[0] signal=%q want importDocument", hist[0].signal)
	}
	// staging 路径应不含原始文件名 (避免逗号/特殊字符), 仅 token + 扩展
	if !strings.HasSuffix(hist[0].value, ".pdf") || strings.Contains(hist[0].value, "book") {
		t.Errorf("call[0] staging path should be <token>.pdf, got %q", hist[0].value)
	}
	if hist[1].signal != "renameEntry" {
		t.Errorf("call[1] signal=%q want renameEntry", hist[1].signal)
	}
	if hist[1].value != "abc-uuid-123,book" {
		t.Errorf("call[1] value=%q want abc-uuid-123,book", hist[1].value)
	}
	if b, _ := fake.stagedBytes.Load().([]byte); !bytes.Equal(b, []byte("%PDF-1.4 fake")) {
		t.Errorf("staged bytes mismatch: %q", b)
	}
}

// 文件名含 ',' 的回归测试: librarian 用 lastIndexOf(',') 切 path/parentId,
// staging 文件名必须不含原始字符, 否则会被误切.
func TestUploadDocumentFilenameWithCommas(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{response: "uuid-with-commas"}
	withFakeLibrarian(t, fake)

	dirty := "Book (z-library.sk, 1lib.sk, z-lib.sk).epub"
	body, ct := multipartUpload(t, "file", dirty, "application/epub+zip", []byte("epub"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != 200 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	fake.mu.Lock()
	hist := append([]fakeLibCall(nil), fake.history...)
	fake.mu.Unlock()
	if len(hist) != 2 {
		t.Fatalf("expected 2 calls, got %d: %+v", len(hist), hist)
	}
	if strings.Contains(hist[0].value, ",") {
		t.Errorf("staging path must not contain ',' but got %q", hist[0].value)
	}
	want := "uuid-with-commas," + strings.TrimSuffix(dirty, ".epub")
	if hist[1].value != want {
		t.Errorf("renameEntry value=%q want %q", hist[1].value, want)
	}
}

func TestUploadDocumentRejectsExe(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{}
	withFakeLibrarian(t, fake)

	body, ct := multipartUpload(t, "file", "evil.exe", "", []byte("MZ"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 400 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	if fake.calls.Load() != 0 {
		t.Errorf("librarian should not be invoked for rejected ext")
	}
}

func TestUploadDocumentPipeMissing(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{err: librarian.ErrPipeMissing}
	withFakeLibrarian(t, fake)
	body, ct := multipartUpload(t, "file", "x.pdf", "", []byte("x"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 503 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
}

func TestUploadDocumentTimeout(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{err: librarian.ErrTimeout}
	withFakeLibrarian(t, fake)
	body, ct := multipartUpload(t, "file", "x.pdf", "", []byte("x"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 503 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
}

func TestUploadDocumentLibrarianError(t *testing.T) {
	_, h, _ := newTestServer(t)
	fake := &fakeLibrarian{response: "ERROR: file does not exist: /tmp/foo"}
	withFakeLibrarian(t, fake)
	body, ct := multipartUpload(t, "file", "x.pdf", "", []byte("x"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 500 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	var resp map[string]string
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if !strings.HasPrefix(resp["detail"], "ERROR:") {
		t.Errorf("expected ERROR: prefix, got %q", resp["detail"])
	}
}

func TestStagingFileCleanedUp(t *testing.T) {
	_, h, root := newTestServer(t)
	fake := &fakeLibrarian{response: "u-1"}
	withFakeLibrarian(t, fake)
	body, ct := multipartUpload(t, "file", "x.pdf", "", []byte("data"))
	req := httptest.NewRequest("POST", "/documents", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body)
	}
	staging := filepath.Join(root, "staging")
	entries, _ := os.ReadDir(staging)
	if len(entries) != 0 {
		t.Errorf("staging dir not cleaned: %v", entries)
	}
}

func TestQRPage(t *testing.T) {
	_, h, _ := newTestServer(t)
	req := httptest.NewRequest("GET", "/qr", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status=%d", rr.Code)
	}
	body, _ := io.ReadAll(rr.Body)
	if !bytes.Contains(body, []byte("上传到 reMarkable")) {
		t.Errorf("qr.html content missing")
	}
}

// 确保无意中的回退 (httpError 只用 JSON)
var _ = errors.Is
