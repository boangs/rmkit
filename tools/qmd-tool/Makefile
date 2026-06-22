# tools/qmd-tool: hash-qmd + qmd-hash-check 的 Go 重写
# build 命令必须与 .github/workflows/ci.yml 一致.
#
# 平台矩阵:
#   host  = 当前 OS/arch (跑 make build 的机器, 留作向后兼容)
#   hosts = 5 个 PC 平台预编译 (Mac arm64/Intel + Linux amd64/arm64 + Windows amd64)
#           install.sh 用 uname 自动选, 这样 Windows/WSL/Linux 用户拿 release 直接能跑
#   aarch64/armv7 = 设备架构, OTA 时设备端也用 qmd-tool 重 hash

DIST := ../../dist
GO_FLAGS := -trimpath -ldflags=-s\ -w

.PHONY: all build clean test vet aarch64 armv7 host hosts \
        host-darwin-arm64 host-darwin-amd64 host-linux-amd64 host-linux-arm64 host-windows-amd64

all: build

# 默认: 全平台 cross-compile (PC 5 平台 + 设备 2 架构 + host 兼容副本)
build: hosts aarch64 armv7

# host = 当前 OS/arch (向后兼容, install.sh 老路径仍工作)
host:
	go build $(GO_FLAGS) -o $(DIST)/qmd-tool .

# hosts = 5 个 PC 平台预编译
hosts: host-darwin-arm64 host-darwin-amd64 host-linux-amd64 host-linux-arm64 host-windows-amd64

host-darwin-arm64:
	GOOS=darwin GOARCH=arm64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-darwin-arm64 .

host-darwin-amd64:
	GOOS=darwin GOARCH=amd64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-darwin-amd64 .

host-linux-amd64:
	GOOS=linux GOARCH=amd64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-linux-amd64 .

host-linux-arm64:
	GOOS=linux GOARCH=arm64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-linux-arm64 .

host-windows-amd64:
	GOOS=windows GOARCH=amd64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-windows-amd64.exe .

aarch64:
	GOOS=linux GOARCH=arm64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-aarch64 .

armv7:
	GOOS=linux GOARCH=arm GOARM=7 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-armv7 .

vet:
	go vet ./...

test:
	go test ./...

clean:
	rm -f $(DIST)/qmd-tool $(DIST)/qmd-tool-aarch64 $(DIST)/qmd-tool-armv7 \
	      $(DIST)/qmd-tool-darwin-arm64 $(DIST)/qmd-tool-darwin-amd64 \
	      $(DIST)/qmd-tool-linux-amd64 $(DIST)/qmd-tool-linux-arm64 \
	      $(DIST)/qmd-tool-windows-amd64.exe
