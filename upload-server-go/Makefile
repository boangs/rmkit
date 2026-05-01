# upload-server-go: 扫码上传 / 字体&截图管理 / AI 配置后端
# build 命令必须与 .github/workflows/ci.yml 保持一致.
# -s -w 实测让 upload-server-aarch64 从 ~9.2MB 瘦到 ~6MB.

DIST := ../dist
GO_FLAGS := -trimpath -ldflags=-s\ -w

.PHONY: all build clean test vet aarch64 armv7

all: build

build: aarch64 armv7

aarch64:
	GOOS=linux GOARCH=arm64 go build $(GO_FLAGS) \
		-o $(DIST)/upload-server-aarch64 ./cmd/upload-server

armv7:
	GOOS=linux GOARCH=arm GOARM=7 go build $(GO_FLAGS) \
		-o $(DIST)/upload-server-armv7 ./cmd/upload-server

vet:
	go vet ./...

test:
	go test ./...

clean:
	rm -f $(DIST)/upload-server-aarch64 $(DIST)/upload-server-armv7
