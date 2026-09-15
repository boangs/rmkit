package server

// 蓝牙 + 音乐 (高级面板"蓝牙"页):
//   - 蓝牙用原厂自带的 bluetoothd 5.72 + bluetoothctl (非交互模式), 扫描/配对/连接耳机;
//     控制器由 btnxpuart 驱动提供, 原厂不加载, 这里按需 modprobe。
//   - 放歌用 rmkit-audio (交叉编译的 bluez-alsa + alsa-lib + mpg123, 装在
//     /home/root/.local/opt/rmkit-audio): bluealsa 做 A2DP 音源, mpg123 经 ALSA 的 bluealsa
//     插件把 PCM 送到耳机。设备本身没有扬声器, 蓝牙是唯一出声口。

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	audioPrefix = "/home/root/.local/opt/rmkit-audio"
)

var btDeviceLine = regexp.MustCompile(`^Device ([0-9A-F:]{17}) (.*)`)

type btDevice struct {
	MAC       string `json:"mac"`
	Name      string `json:"name"`
	Paired    bool   `json:"paired"`
	Connected bool   `json:"connected"`
}

// btctl 跑一条 bluetoothctl 命令, 超时秒数由调用方定 (bluetoothctl --timeout 只对 scan 有效,
// 其它命令自己会结束; 外层再加 exec 超时兜底)。
func btctl(timeout time.Duration, args ...string) (string, error) {
	cmd := exec.Command("bluetoothctl", args...)
	cmd.Env = append(os.Environ(), "TERM=dumb")
	done := make(chan struct{})
	var out []byte
	var err error
	go func() { out, err = cmd.CombinedOutput(); close(done) }()
	select {
	case <-done:
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		if err == nil {
			err = errors.New("bluetoothctl 超时")
		}
	}
	// 去掉 ANSI 颜色
	clean := regexp.MustCompile(`\x1b\[[0-9;]*m`).ReplaceAllString(string(out), "")
	return clean, err
}

// btEnsureAdapter 保证 hci0 存在且已上电 (原厂不加载 btnxpuart)。
func btEnsureAdapter() error {
	if _, err := os.Stat("/sys/class/bluetooth/hci0"); err != nil {
		_ = exec.Command("modprobe", "btnxpuart").Run()
	}
	// 首次加载要往芯片下载固件 (nxp/uartspi_n61x_v1.bin.se), 实测 5-10 秒; 期间控制器还没注册到 bluetoothd。
	// 这段时间里绝对不能 rmmod/复位 (2026-09-14 事故: 下载被打断 → "FW Download Aborted" → 芯片只能断电救),
	// 只能耐心轮询。
	_ = exec.Command("rfkill", "unblock", "bluetooth").Run()
	var show string
	for i := 0; i < 60; i++ {
		show, _ = btctl(5*time.Second, "show")
		if strings.Contains(show, "Powered:") {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !strings.Contains(show, "Powered:") {
		return errors.New("蓝牙控制器 30 秒内没就绪 (看 dmesg | grep hci0; 若有 tx timeout / FW already running, 需长按电源键彻底关机再开)")
	}
	if !strings.Contains(show, "Powered: yes") {
		if out, _ := btctl(10*time.Second, "power", "on"); !strings.Contains(out, "succeeded") {
			return errors.New("蓝牙上电失败: " + lastLine(out))
		}
	}
	btStartKeepalive() // 见 btkeepalive.go: 不让芯片进省电 (驱动唤醒握手不可靠)
	return nil
}

func parseDevices(out string) []btDevice {
	var list []btDevice
	seen := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		m := btDeviceLine.FindStringSubmatch(sc.Text())
		if m == nil || seen[m[1]] {
			continue
		}
		seen[m[1]] = true
		list = append(list, btDevice{MAC: m[1], Name: strings.TrimSpace(m[2])})
	}
	return list
}

// btStep 是交互式 bluetoothctl 会话里的一步: 发命令, 然后最多等 wait, 期间输出命中 until 任一子串就提前结束。
type btStep struct {
	cmd   string
	wait  time.Duration
	until []string
}

// btSession 把多条命令喂给同一个 bluetoothctl 进程 (stdin 管道)。
// 必须同会话: bluetoothd 只在发现会话存活期间保留扫描到的临时设备, 单独起 `bluetoothctl pair` 会报 "not available"。
// 扫描限定 bredr: 耳机同时广播 LE (厂商快连) 与经典链路, 默认双模发现会优先走 LE 配对 → AuthenticationTimeout。
func btSession(total time.Duration, steps []btStep) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), total)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bluetoothctl")
	cmd.Env = append(os.Environ(), "TERM=dumb")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return "", err
	}
	var mu sync.Mutex
	var buf strings.Builder
	ansi := regexp.MustCompile(`\x1b\[[0-9;]*m`)
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 64*1024), 1024*1024)
		for sc.Scan() {
			line := ansi.ReplaceAllString(sc.Text(), "")
			if i := strings.Index(line, "]# "); i >= 0 {
				line = line[i+3:]
			}
			mu.Lock()
			buf.WriteString(strings.TrimSpace(line) + "\n")
			mu.Unlock()
		}
	}()
	snapshot := func() string { mu.Lock(); defer mu.Unlock(); return buf.String() }
	for _, st := range steps {
		if ctx.Err() != nil {
			break
		}
		mark := len(snapshot())
		if _, err := io.WriteString(stdin, st.cmd+"\n"); err != nil {
			break
		}
		deadline := time.Now().Add(st.wait)
		for time.Now().Before(deadline) && ctx.Err() == nil {
			time.Sleep(250 * time.Millisecond)
			if len(st.until) == 0 {
				continue
			}
			out := snapshot()[mark:]
			hit := false
			for _, u := range st.until {
				if strings.Contains(out, u) {
					hit = true
					break
				}
			}
			if hit {
				break
			}
		}
	}
	_, _ = io.WriteString(stdin, "quit\n")
	_ = stdin.Close()
	_ = cmd.Wait()
	<-readDone
	return snapshot(), ctx.Err()
}

// btScanSteps 在会话里开一轮只看经典链路 (bredr) 的扫描。
func btScanSteps(secs int) []btStep {
	return []btStep{
		{cmd: "menu scan", wait: 300 * time.Millisecond},
		{cmd: "transport bredr", wait: 300 * time.Millisecond},
		{cmd: "back", wait: 300 * time.Millisecond},
		{cmd: "scan on", wait: time.Duration(secs) * time.Second},
	}
}

// btList 汇总设备: 已配对 + 已连接标记 + 扫描到的 (只保留有名字的, 匿名 MAC 对用户没意义)。
func btList(includeScanned bool) []btDevice {
	paired, _ := btctl(8*time.Second, "devices", "Paired")
	connected, _ := btctl(8*time.Second, "devices", "Connected")
	all, _ := btctl(8*time.Second, "devices")
	isPaired, isConn := map[string]bool{}, map[string]bool{}
	for _, d := range parseDevices(paired) {
		isPaired[d.MAC] = true
	}
	for _, d := range parseDevices(connected) {
		isConn[d.MAC] = true
	}
	var list []btDevice
	for _, d := range parseDevices(all) {
		d.Paired, d.Connected = isPaired[d.MAC], isConn[d.MAC]
		anonymous := strings.ReplaceAll(d.MAC, ":", "-") == d.Name
		if !d.Paired && (!includeScanned || anonymous) {
			continue
		}
		list = append(list, d)
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].Connected != list[j].Connected {
			return list[i].Connected
		}
		if list[i].Paired != list[j].Paired {
			return list[i].Paired
		}
		return list[i].Name < list[j].Name
	})
	return list
}

func (s *Server) btStatus(w http.ResponseWriter, r *http.Request) {
	adapter := "absent"
	if _, err := os.Stat("/sys/class/bluetooth/hci0"); err == nil {
		adapter = "present"
		show, _ := btctl(6*time.Second, "show")
		if strings.Contains(show, "Powered: yes") {
			adapter = "powered"
		}
	}
	_, audioReady := os.Stat(audioPrefix + "/bin/bluealsa")
	writeJSON(w, http.StatusOK, map[string]any{
		"adapter":    adapter,
		"devices":    btList(false),
		"audioReady": audioReady == nil,
	})
}

// btMerge 把扫描会话里 `devices` 列出的设备并进已配对列表 (去重, 过滤匿名 MAC)。
func btMerge(base []btDevice, scanned []btDevice) []btDevice {
	seen := map[string]bool{}
	for _, d := range base {
		seen[d.MAC] = true
	}
	for _, d := range scanned {
		if seen[d.MAC] || strings.ReplaceAll(d.MAC, ":", "-") == d.Name {
			continue
		}
		seen[d.MAC] = true
		base = append(base, d)
	}
	sort.SliceStable(base, func(i, j int) bool {
		if base[i].Connected != base[j].Connected {
			return base[i].Connected
		}
		if base[i].Paired != base[j].Paired {
			return base[i].Paired
		}
		return base[i].Name < base[j].Name
	})
	return base
}

func (s *Server) btScan(w http.ResponseWriter, r *http.Request) {
	if err := btEnsureAdapter(); err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	secs := 10
	if v, err := strconv.Atoi(r.URL.Query().Get("seconds")); err == nil && v > 0 && v <= 30 {
		secs = v
	}
	// 扫描和 `devices` 必须在同一会话里, 否则会话结束临时设备就被 bluetoothd 清掉了
	out, _ := btSession(time.Duration(secs+15)*time.Second, append(btScanSteps(secs),
		btStep{cmd: "scan off", wait: 1 * time.Second, until: []string{"Discovery stopped"}},
		btStep{cmd: "devices", wait: 2 * time.Second},
	))
	writeJSON(w, http.StatusOK, map[string]any{"devices": btMerge(btList(false), parseDevices(out))})
}

func macFromRequest(r *http.Request) (string, error) {
	var body struct {
		MAC string `json:"mac"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	mac := strings.ToUpper(strings.TrimSpace(body.MAC))
	if !regexp.MustCompile(`^[0-9A-F:]{17}$`).MatchString(mac) {
		return "", errors.New("mac 参数无效")
	}
	return mac, nil
}

// btPair 配对 + 信任 + 连接 (耳机一般是 just-works, 不需要 PIN)。
func (s *Server) btPair(w http.ResponseWriter, r *http.Request) {
	mac, err := macFromRequest(r)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := btEnsureAdapter(); err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	_ = ensureBluealsa() // A2DP profile 要先于耳机连接注册到 bluetoothd, 否则连上了也 "PCM not found"
	steps := append([]btStep{{cmd: "pairable on", wait: 500 * time.Millisecond}}, btScanSteps(8)...)
	steps = append(steps,
		btStep{cmd: "pair " + mac, wait: 35 * time.Second, until: []string{"Pairing successful", "Failed to pair", "not available", "AlreadyExists"}},
		btStep{cmd: "scan off", wait: 1 * time.Second, until: []string{"Discovery stopped"}},
		btStep{cmd: "trust " + mac, wait: 2 * time.Second, until: []string{"trust succeeded", "not available"}},
		btStep{cmd: "connect " + mac, wait: 20 * time.Second, until: []string{"Connection successful", "Failed to connect", "not available"}},
	)
	out, _ := btSession(90*time.Second, steps)
	if !strings.Contains(out, "Pairing successful") && !strings.Contains(out, "AlreadyExists") {
		reason := "耳机没找到"
		for _, l := range strings.Split(out, "\n") {
			if strings.Contains(l, "Failed to pair") || strings.Contains(l, "not available") {
				reason = strings.TrimSpace(l)
			}
		}
		log.Printf("bt pair %s 失败: %s\n--- bluetoothctl 会话 ---\n%s", mac, reason, out)
		httpError(w, http.StatusBadGateway, "配对失败: "+reason+" (请让耳机进入配对模式后重试)")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"paired": true, "connected": strings.Contains(out, "Connection successful")})
}

func (s *Server) btConnect(w http.ResponseWriter, r *http.Request) {
	mac, err := macFromRequest(r)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := btEnsureAdapter(); err != nil {
		httpError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	_ = ensureBluealsa() // 同 btPair: profile 先注册再连
	out, _ := btctl(30*time.Second, "connect", mac)
	if !strings.Contains(out, "Connection successful") {
		httpError(w, http.StatusBadGateway, "连接失败: "+lastLine(out)+" (耳机要先开机并离开其它设备)")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"connected": true})
}

func (s *Server) btDisconnect(w http.ResponseWriter, r *http.Request) {
	mac, err := macFromRequest(r)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	out, _ := btctl(15*time.Second, "disconnect", mac)
	writeJSON(w, http.StatusOK, map[string]any{"detail": lastLine(out)})
}

func (s *Server) btRemove(w http.ResponseWriter, r *http.Request) {
	mac, err := macFromRequest(r)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	out, _ := btctl(15*time.Second, "remove", mac)
	writeJSON(w, http.StatusOK, map[string]any{"detail": lastLine(out)})
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) == 0 {
		return ""
	}
	return strings.TrimSpace(lines[len(lines)-1])
}

// ───── 蓝牙音频 (bluealsa A2DP 音源) ─────

func audioEnv() []string {
	return append(os.Environ(),
		"LD_LIBRARY_PATH="+audioPrefix+"/lib",
		"ALSA_CONFIG_PATH="+audioPrefix+"/share/alsa/alsa.conf",
		"ALSA_PLUGIN_DIR="+audioPrefix+"/lib/alsa-lib",
	)
}

// ensureBluealsa 保证 A2DP 音源守护进程在跑。
func ensureBluealsa() error {
	if _, err := os.Stat(audioPrefix + "/bin/bluealsa"); err != nil {
		return errors.New("未安装 rmkit-audio (蓝牙音频组件)")
	}
	if out, _ := exec.Command("pgrep", "-x", "bluealsa").Output(); len(out) > 0 {
		return nil
	}
	// D-Bus 系统总线策略: bluealsa 要独占 org.bluealsa 名字。/etc 是 tmpfs overlay 上层, 重启即丢,
	// 所以不双写 ext4 下层 (ferrari 冷启动事故), 而是每次起 bluealsa 前补一次并让 dbus 重载配置。
	const policy = "/etc/dbus-1/system.d/bluealsa.conf"
	want, err := os.ReadFile(audioPrefix + "/etc/dbus-1/system.d/bluealsa.conf")
	if err != nil {
		return errors.New("rmkit-audio 缺 D-Bus 策略文件: " + err.Error())
	}
	if have, _ := os.ReadFile(policy); string(have) != string(want) {
		_ = os.MkdirAll(filepath.Dir(policy), 0o755)
		if err := os.WriteFile(policy, want, 0o644); err != nil {
			return errors.New("写 D-Bus 策略失败: " + err.Error())
		}
		_ = exec.Command("busctl", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReloadConfig").Run()
	}
	// bluealsa 的存储目录在前缀下的 var/lib (交叉编译时 localstatedir 默认 $prefix/var); /var/lib 是 tmpfs overlay
	_ = os.MkdirAll(audioPrefix+"/var/lib/bluealsa", 0o755)
	_ = os.MkdirAll("/var/lib/bluealsa", 0o755)
	// SBC 用 medium 码率: high (~330kbps) 在这块板的 UART 蓝牙链路上会时快时慢, medium 实测稳定
	cmd := exec.Command(audioPrefix+"/bin/bluealsa", "-p", "a2dp-source", "--sbc-quality=medium")
	cmd.Env = audioEnv()
	cmd.SysProcAttr = newSessionLeader()
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	time.Sleep(1500 * time.Millisecond)
	return nil
}

// StartAudioDaemon 在 upload-server 启动时后台拉起 bluealsa: 耳机出盒会自动回连已信任的设备,
// 那一刻 A2DP profile 必须已经注册, 否则要手动断开重连才有声音。未装 rmkit-audio 时静默跳过。
func StartAudioDaemon() {
	btStartKeepalive() // 只要 hci0 在就保活 (循环里自己判断), 不依赖面板先点过蓝牙页
	if _, err := os.Stat(audioPrefix + "/bin/bluealsa"); err != nil {
		return
	}
	go func() {
		if err := ensureBluealsa(); err != nil {
			log.Printf("bluealsa 启动失败: %v", err)
		}
	}()
}
