# tools/qmd-tool: hash-qmd + qmd-hash-check 的 Go 重写
# build 命令必须与 .github/workflows/ci.yml 一致.
# 三平台 cross-compile: host (PC install.sh 用) + aarch64/armv7 (设备 OTA 用).

DIST := ../../dist
GO_FLAGS := -trimpath -ldflags=-s\ -w

.PHONY: all build clean test vet aarch64 armv7 host

all: build

# 默认: 三平台都编 (PC + 两个设备架构)
build: host aarch64 armv7

# host = 当前 OS/arch (macOS/linux 上跑 install.sh 用)
host:
	go build $(GO_FLAGS) -o $(DIST)/qmd-tool .

aarch64:
	GOOS=linux GOARCH=arm64 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-aarch64 .

armv7:
	GOOS=linux GOARCH=arm GOARM=7 go build $(GO_FLAGS) -o $(DIST)/qmd-tool-armv7 .

vet:
	go vet ./...

test:
	go test ./...

clean:
	rm -f $(DIST)/qmd-tool $(DIST)/qmd-tool-aarch64 $(DIST)/qmd-tool-armv7
