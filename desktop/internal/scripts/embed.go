// Package scripts 内嵌所有在设备端执行的 bash。
//
// rmkit-cn 的几段 (receive-payload / rime-setup / deploy-stages / uninstall) 是从
// installer/install.sh 原样提取的: 六阶段防砖部署、hashtab 重生、drop-in 双写、启动核验
// 这些逻辑已经在三台机型上反复验证, 桌面助手只替换主机侧 (连接/探测/组装/传输), 不重写它们。
package scripts

import _ "embed"

//go:embed receive-payload.sh
var ReceivePayload string

//go:embed rime-setup.sh
var RimeSetup string

//go:embed deploy-stages.sh
var DeployStages string

//go:embed uninstall.sh
var Uninstall string

//go:embed android-install.sh
var AndroidInstall string

//go:embed android-uninstall.sh
var AndroidUninstall string
