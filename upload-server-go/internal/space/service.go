package space

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Supervisor 托管应用自带的后台进程: 按 manifest.service 拉起、探测就绪、收掉。
// 每个应用最多一个进程; 进程组整体收, 避免留孤儿。
type Supervisor struct {
	BaseURL string // upload-server 自己的地址, 通过环境变量告诉应用后端

	mu    sync.Mutex
	procs map[string]*proc
}

type proc struct {
	app     App
	cmd     *exec.Cmd
	started time.Time
	done    chan struct{}
	exitErr error
}

// ServiceStatus 是 /space/apps/{id}/service 的返回。
type ServiceStatus struct {
	ID      string  `json:"id"`
	Running bool    `json:"running"`
	PID     int     `json:"pid,omitempty"`
	URL     string  `json:"url,omitempty"`
	Uptime  float64 `json:"uptime,omitempty"` // 秒
	Error   string  `json:"error,omitempty"`
}

func NewSupervisor(baseURL string) *Supervisor {
	return &Supervisor{BaseURL: baseURL, procs: map[string]*proc{}}
}

// Start 拉起应用后台 (已在跑则直接返回状态)。声明了端口时会等到端口能响应或超时。
func (s *Supervisor) Start(app App) (ServiceStatus, error) {
	if app.Service == nil {
		return ServiceStatus{}, errors.New("该应用没有声明后台 (manifest.service)")
	}
	if app.Error != "" {
		return ServiceStatus{}, errors.New(app.Error)
	}
	s.mu.Lock()
	if p, ok := s.procs[app.ID]; ok && p.alive() {
		s.mu.Unlock()
		return s.Status(app.ID), nil
	}
	s.mu.Unlock()

	exe := filepath.Join(app.Dir, app.Service.Exec)
	if _, err := os.Stat(exe); err != nil {
		return ServiceStatus{}, fmt.Errorf("后台可执行文件不存在: %s", app.Service.Exec)
	}
	_ = os.Chmod(exe, 0o755)
	_ = os.MkdirAll(app.DataDir, 0o755)
	logf, err := os.Create(filepath.Join(app.DataDir, "service.log"))
	if err != nil {
		return ServiceStatus{}, err
	}
	cmd := exec.Command(exe, app.Service.Args...)
	cmd.Dir = app.Dir
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.Env = append(os.Environ(),
		"SPACE_APP_ID="+app.ID,
		"SPACE_APP_DIR="+app.Dir,
		"SPACE_DATA_DIR="+app.DataDir,
		"SPACE_PORT="+strconv.Itoa(app.Service.Port),
		"SPACE_BASE_URL="+s.BaseURL,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // 进程组: 收的时候连子进程一起
	if err := cmd.Start(); err != nil {
		logf.Close()
		return ServiceStatus{}, err
	}
	p := &proc{app: app, cmd: cmd, started: time.Now(), done: make(chan struct{})}
	go func() {
		p.exitErr = cmd.Wait()
		logf.Close()
		close(p.done)
	}()
	s.mu.Lock()
	s.procs[app.ID] = p
	s.mu.Unlock()

	if err := s.waitReady(p); err != nil {
		_ = s.Stop(app.ID)
		return ServiceStatus{}, err
	}
	return s.Status(app.ID), nil
}

// waitReady: 声明端口的等 HTTP 有响应 (任何状态码都算活), 没声明的只确认没秒退。
func (s *Supervisor) waitReady(p *proc) error {
	svc := p.app.Service
	deadline := time.Now().Add(15 * time.Second)
	client := &http.Client{Timeout: 800 * time.Millisecond}
	health := svc.Health
	if health == "" {
		health = "/"
	}
	for {
		select {
		case <-p.done:
			return fmt.Errorf("后台启动后立即退出: %v\n%s", p.exitErr, tailLog(p.app.DataDir))
		default:
		}
		if svc.Port == 0 {
			if time.Since(p.started) > 500*time.Millisecond {
				return nil
			}
		} else {
			resp, err := client.Get("http://127.0.0.1:" + strconv.Itoa(svc.Port) + health)
			if err == nil {
				resp.Body.Close()
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("后台 %d 端口 15 秒内没就绪\n%s", svc.Port, tailLog(p.app.DataDir))
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// Stop 收掉应用后台 (先 TERM 进程组, 3 秒不退再 KILL)。没在跑不算错。
func (s *Supervisor) Stop(id string) error {
	s.mu.Lock()
	p, ok := s.procs[id]
	if ok {
		delete(s.procs, id)
	}
	s.mu.Unlock()
	if !ok || !p.alive() {
		return nil
	}
	pgid := -p.cmd.Process.Pid
	_ = syscall.Kill(pgid, syscall.SIGTERM)
	select {
	case <-p.done:
		return nil
	case <-time.After(3 * time.Second):
	}
	_ = syscall.Kill(pgid, syscall.SIGKILL)
	select {
	case <-p.done:
	case <-time.After(2 * time.Second):
		return errors.New("后台进程 KILL 后仍未退出")
	}
	return nil
}

// StopAll 在 upload-server 退出时把所有应用后台一起收掉。
func (s *Supervisor) StopAll() {
	s.mu.Lock()
	ids := make([]string, 0, len(s.procs))
	for id := range s.procs {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	for _, id := range ids {
		_ = s.Stop(id)
	}
}

// Status 返回应用后台的当前状态。
func (s *Supervisor) Status(id string) ServiceStatus {
	s.mu.Lock()
	p, ok := s.procs[id]
	s.mu.Unlock()
	st := ServiceStatus{ID: id}
	if !ok {
		return st
	}
	if !p.alive() {
		if p.exitErr != nil {
			st.Error = "已退出: " + p.exitErr.Error()
		}
		return st
	}
	st.Running = true
	st.PID = p.cmd.Process.Pid
	st.URL = p.app.ServiceURL
	st.Uptime = time.Since(p.started).Seconds()
	return st
}

func (p *proc) alive() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

func tailLog(dataDir string) string {
	b, err := os.ReadFile(filepath.Join(dataDir, "service.log"))
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) > 12 {
		lines = lines[len(lines)-12:]
	}
	return strings.Join(lines, "\n")
}
