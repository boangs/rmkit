# ime-go: 拼音 IME 服务 (rime-frost FST 词库 embed)
# build 命令必须与 .github/workflows/ci.yml 保持一致, 否则本地产物
# (dist/ime-server*) 会比 CI release 多 ~30% 体积 (DWARF + 符号表).
#
# 注: ime-server 实测 ~18MB, 90% 是 rime-frost 词库 embed; -s -w
# 砍不动这部分, 真要瘦身需把词库剥出二进制 (作为单独 .bin 部署).

DIST := ../dist
GO_FLAGS := -trimpath -ldflags=-s\ -w

.PHONY: all build clean test vet aarch64 armv7

all: build

build: aarch64 armv7

aarch64:
	GOOS=linux GOARCH=arm64 go build $(GO_FLAGS) \
		-o $(DIST)/ime-server ./cmd/ime-server

armv7:
	GOOS=linux GOARCH=arm GOARM=7 go build $(GO_FLAGS) \
		-o $(DIST)/ime-server-armv7 ./cmd/ime-server

vet:
	go vet ./...

test:
	go test ./...

clean:
	rm -f $(DIST)/ime-server $(DIST)/ime-server-armv7
