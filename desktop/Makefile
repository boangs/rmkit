# rmkit 助手 (Wails v2 桌面程序)
#   make bundle-rmkit      从仓库产物生成 rmkit-cn 载荷包 (需先 build dist/ 或从 Release 解压)
#   make bundle-android    从 ANDROID_DIR 生成 android-rmppm 载荷包
#   make build-mac         构建 macOS .app (build/bin/)
#   make build-win         交叉构建 Windows exe
#   make cli               构建命令行版 (无 GUI, 同一套内核)
WAILS ?= $(HOME)/go/bin/wails
ANDROID_DIR ?= ../../paper-move-android/android-bundle
VERSION ?= $(shell git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: bundle-rmkit bundle-android build-mac build-win cli dev vet

bundle-rmkit:
	go run ./cmd/mkbundle -component rmkit-cn -repo .. -version $(VERSION) -out dist/rmkit-cn-bundle.zip

bundle-android:
	go run ./cmd/mkbundle -component android-rmppm -android-dir $(ANDROID_DIR) -version $(VERSION) -out dist/android-rmppm-bundle.zip

build-mac:
	$(WAILS) build -clean -platform darwin/universal

build-win:
	$(WAILS) build -clean -platform windows/amd64 -o rmkit-assistant.exe

cli:
	GOOS=darwin GOARCH=arm64 go build -trimpath -o dist/assistant-cli-darwin-arm64 ./cmd/assistant-cli
	GOOS=windows GOARCH=amd64 go build -trimpath -o dist/assistant-cli-windows-amd64.exe ./cmd/assistant-cli

dev:
	$(WAILS) dev

vet:
	go vet ./... && cd frontend && npx tsc --noEmit
