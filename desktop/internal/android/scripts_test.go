package android

import (
	"regexp"
	"testing"

	"github.com/rmkit-cn/desktop/internal/scripts"
)

// 设备端脚本里每个 $STAGE/<文件> 引用都必须是载荷清单 (required 或可选的系统包) 里的名字,
// 否则装到一半才报 "No such file" (2026-09-07 两次踩坑: 漏 .tmpl 后缀)。
func TestAndroidInstallScriptReferencesMatchBundle(t *testing.T) {
	known := map[string]bool{"android-system.tar.gz": true}
	for _, r := range required {
		known[r] = true
	}
	re := regexp.MustCompile(`\$STAGE/([A-Za-z0-9_.+-]+)`)
	for _, m := range re.FindAllStringSubmatch(scripts.AndroidInstall, -1) {
		if !known[m[1]] {
			t.Errorf("android-install.sh 引用了载荷里没有的文件: %s", m[1])
		}
	}
}
