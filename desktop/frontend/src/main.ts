import './style.css'
import {
  Connect, Disconnect, Probe, ChooseBundle, DownloadBundle, PlanRmkit, RunRmkit, UninstallRmkit,
  PlanAndroid, RunAndroid, UninstallAndroid, BootAndroid, ReturnToStock, ResetAndroidData, ChooseAPKs, InstallAPKs, Cancel, OpenLogDir, LogDir, DetectProxy, Confirm, LoadPassword, ForgetPassword, DiagnoseAndroid,
} from '../wailsjs/go/main/App'
import { EventsOn } from '../wailsjs/runtime/runtime'

// 与 Go 端结构一一对应 (wailsjs/go/models.ts 里也有生成的类型, 这里只声明用到的字段)
type Info = {
  arch: string; fwVersion: string; resolution: string; model: string; modelKey: string
  activeSlot: string; errcntA: number; errcntB: number; secboot: string
  rootFreeMB: number; homeFreeMB: number; haveXovi: boolean; rmkitInstalled: boolean; rmkitFW: string
  xochitlActive: boolean; inAndroidMode: boolean; androidInstalled: boolean; initIsWrapper: boolean
}
type BundleInfo = { path: string; component: string; version: string; created: string; notes: string; files: number; bytes: number }
type FileEntry = { device: string; source: string; mode: number; size: number }
type RmkitPlan = { arch: string; fwVersion: string; needXovi: boolean; deployRime: boolean; qmlInject: boolean; librarian: boolean; files: FileEntry[]; totalBytes: number; warnings: string[] }
type AndroidPlan = { fwVersion: string; slot: string; hasSystemPkg: boolean; replaceSystem: boolean; systemPresent: boolean; files: string[]; totalBytes: number; warnings: string[]; blockers: string[] }

type Action = 'rmkit' | 'android'

const state = {
  info: null as Info | null,
  bundle: null as BundleInfo | null,
  action: 'rmkit' as Action,
  busy: false,
  replaceSystem: false,
  removeData: false,
  proxy: '',
  remember: true,
  password: '',
}

const RELEASE_BASE = 'https://github.com/boangs/rmkit/releases/latest/download/'

const $ = (sel: string) => document.querySelector(sel) as HTMLElement
const mb = (n: number) => (n / 1e6).toFixed(1) + ' MB'
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string))

function render() {
  const app = $('#app')
  app.innerHTML = `
    <header>
      <h1>rmkit 助手</h1>
      <p class="sub">只走 USB 线直连你的 reMarkable。没有服务器，不读你的笔记，每一步都记在本机日志里。</p>
    </header>

    <section class="card" id="card-connect">
      <h2>1. 连接设备</h2>
      <div class="row">
        <label>地址 <input id="host" value="10.11.99.1" size="14" ${state.info ? 'disabled' : ''}></label>
        <label>SSH 密码 <input id="password" type="password" size="16" value="${esc(state.password)}" ${state.info ? 'disabled' : ''}></label>
        <label class="check"><input type="checkbox" id="chk-remember" ${state.remember ? 'checked' : ''} ${state.info ? 'disabled' : ''}> 记住密码</label>
        ${state.info
          ? `<button id="btn-disconnect" class="secondary">断开</button><button id="btn-probe" class="secondary">重新检测</button>`
          : `<button id="btn-connect" class="primary">连接并检测</button><button id="btn-forget" class="secondary" ${state.password ? '' : 'disabled'}>忘记密码</button>`}
      </div>
      <p class="hint">勾选“记住密码”后密码存在系统钥匙串里（Mac 钥匙串 / Windows 凭据管理器），不会写进文件。Android 模式下的密码和 reMarkable 系统的一样。</p>
      <p class="hint">用 USB 线连上后，设备默认地址是 10.11.99.1。密码在设备 <b>设置 → 帮助 → 版权与许可</b> 页面最底部（Windows 首次连接可能需要装 reMarkable 的 USB 网卡驱动）。</p>
      ${state.info ? renderInfo(state.info) : ''}
    </section>

    ${state.info ? renderActions(state.info) : ''}

    <section class="card">
      <h2>日志</h2>
      <div class="row">
        <button id="btn-logdir" class="secondary">打开日志目录</button>
        ${state.busy ? '<button id="btn-cancel" class="danger">取消</button>' : ''}
      </div>
      <pre id="log"></pre>
    </section>
  `
  bind()
}

function renderInfo(i: Info) {
  const rows: [string, string][] = [
    ['型号', `${i.model} (${i.arch}, ${i.resolution})`],
    ['固件', i.fwVersion || '未知'],
    ['当前模式', i.inAndroidMode ? 'Android' : 'reMarkable 系统' + (i.xochitlActive ? '（xochitl 运行中）' : '')],
    ['启动槽', i.activeSlot ? `${i.activeSlot}，错误计数 a=${i.errcntA} b=${i.errcntB}` : '（该机型无 A/B 槽）'],
    ['剩余空间', `系统分区 ${i.rootFreeMB} MB，/home ${i.homeFreeMB} MB`],
    ['rmkit-cn', i.rmkitInstalled ? `已安装（上次适配固件 ${i.rmkitFW || '未知'}）` : '未安装'],
    ['单槽 Android', i.androidInstalled ? '已安装（本槽）' : '未安装'],
  ]
  return `<table class="info">${rows.map(([k, v]) => `<tr><th>${k}</th><td>${esc(v)}</td></tr>`).join('')}</table>`
}

function renderActions(i: Info) {
  const b = state.bundle
  const busy = state.busy ? 'disabled' : ''
  const bundleOk = b && ((state.action === 'rmkit' && b.component === 'rmkit-cn') || (state.action === 'android' && b.component === 'android-rmppm'))
  const bundleName = state.action === 'rmkit' ? 'rmkit-cn-bundle.zip' : 'android-rmppm-bundle.zip'
  return `
    <section class="card">
      <h2>2. 选择要做的事</h2>
      <div class="tabs">
        <button class="tab ${state.action === 'rmkit' ? 'active' : ''}" data-action="rmkit" ${busy}>rmkit-cn 中文化 / 输入法</button>
        <button class="tab ${state.action === 'android' ? 'active' : ''}" data-action="android" ${busy} ${i.modelKey !== 'rmppm' ? 'title="只支持 Paper Pro Move"' : ''}>Android（仅 Paper Pro Move）</button>
      </div>
      ${state.action === 'android' && i.modelKey !== 'rmppm' ? '<p class="warn">检测到的不是 Paper Pro Move，单槽 Android 只在 Paper Pro Move 上验证过，这里不允许安装。</p>' : ''}

      <h3>载荷包</h3>
      <div class="row">
        <button id="btn-download" class="secondary" ${busy}>从 GitHub Release 下载 ${bundleName}</button>
        <label>代理 <input id="proxy" value="${esc(state.proxy)}" placeholder="如 http://127.0.0.1:7890, 留空直连" size="26" ${busy}></label>
        <button id="btn-choose" class="secondary" ${busy}>选择本地载荷包…</button>
      </div>
      <p class="hint">GitHub 在国内直连常常超时。用了代理软件就把它的地址填在这里（助手会自动探测系统代理）；也可以用浏览器下载载荷包后选本地文件。</p>
      <div id="dl-progress" class="progress hidden"><div></div></div>
      ${b ? `<p class="hint">已加载：${esc(b.path)}<br>组件 ${b.component}，版本 ${b.version}，${b.files} 个文件，${mb(b.bytes)}${bundleOk ? '' : '<b class="warn"> —— 与当前选择的操作不匹配</b>'}</p>` : '<p class="hint">还没有载荷包。载荷包是 rmkit 发布的 zip，助手会逐文件校验 sha256。</p>'}

      <h3>3. 预览并执行</h3>
      ${state.action === 'android' ? `
        <label class="check"><input type="checkbox" id="chk-replace" ${state.replaceSystem ? 'checked' : ''} ${busy}> 覆盖设备上已有的 Android 系统（应用数据目录不受影响）</label>` : ''}
      <div class="row">
        <button id="btn-plan" class="secondary" ${busy || !bundleOk ? 'disabled' : ''}>预览将写入的内容</button>
        <button id="btn-run" class="primary" ${busy || !bundleOk ? 'disabled' : ''}>${state.action === 'rmkit' ? (i.rmkitInstalled ? '更新 rmkit-cn' : '安装 rmkit-cn') : (i.androidInstalled ? '更新 Android' : '安装 Android')}</button>
      </div>
      <div id="plan"></div>

      <h3>其他操作</h3>
      <div class="row">
        ${state.action === 'rmkit'
          ? `<button id="btn-uninstall" class="danger" ${busy || !i.rmkitInstalled ? 'disabled' : ''}>卸载 rmkit-cn</button>`
          : `<button id="btn-boot-android" class="secondary" ${busy || !i.androidInstalled || i.inAndroidMode ? 'disabled' : ''}>重启进 Android</button>
             <button id="btn-stock" class="secondary" ${busy || !i.inAndroidMode ? 'disabled' : ''}>回 reMarkable 系统</button>
             <button id="btn-diag" class="secondary" ${busy} title="收集固件/槽位/内核链接/启动日志, 进不了 Android 时把结果发给开发者">Android 启动诊断</button>
             <button id="btn-apks" class="secondary" ${busy || !i.inAndroidMode ? 'disabled' : ''} title="需要设备在 Android 模式">安装 APK 到 Android…</button>
             <button id="btn-reset-data" class="danger" ${busy || !i.androidInstalled || i.inAndroidMode ? 'disabled' : ''} title="清空 Android 应用与设置, 下次进 Android 重新首启">重置 Android 数据</button>
             <label class="check"><input type="checkbox" id="chk-removedata" ${state.removeData ? 'checked' : ''} ${busy}> 卸载时连同 /home 里的 Android 系统与数据一起删</label>
             <button id="btn-uninstall-android" class="danger" ${busy || !i.androidInstalled || i.inAndroidMode ? 'disabled' : ''}>卸载 Android</button>`}
      </div>
    </section>
  `
}

function renderRmkitPlan(p: RmkitPlan) {
  const flags = [
    p.needXovi ? '设备没有 xovi，会先自动部署' : 'xovi 已在',
    p.deployRime ? '整句输入（librime，拼音+五笔86）' : '纯 Go 输入引擎（载荷无 librime）',
    p.qmlInject ? '运行时 QML 注入' : 'qmd 注入',
    p.librarian ? '文件热导入 librarian' : '不装 librarian（rm2）',
  ]
  return `
    <p>将写入 <b>${(p.files ?? []).length}</b> 个文件，共 ${mb(p.totalBytes)}。${flags.map((f) => `<span class="pill">${f}</span>`).join('')}</p>
    ${(p.warnings ?? []).map((w) => `<p class="warn">⚠ ${esc(w)}</p>`).join('')}
    <p class="hint">写入后设备端会执行六阶段防砖部署：装服务 → 按固件重生 hashtab → 编译注入文件 → 全部命中才写 xochitl 配置 → 启动并观察 10 秒，任一步失败自动回退到出厂启动。</p>
    <details><summary>文件清单</summary><pre class="files">${(p.files ?? []).map((f) => `${esc(f.device)}  ←  ${esc(f.source)}  (${(f.size / 1024).toFixed(0)} KB)`).join('\n')}</pre></details>
  `
}

function renderAndroidPlan(p: AndroidPlan) {
  return `
    ${(p.blockers ?? []).map((b) => `<p class="error">✗ ${esc(b)}</p>`).join('')}
    ${(p.warnings ?? []).map((w) => `<p class="warn">⚠ ${esc(w)}</p>`).join('')}
    <p>本槽 ${esc(p.slot)}，固件 ${esc(p.fwVersion)}。将上传 <b>${(p.files ?? []).length}</b> 个文件，共 ${mb(p.totalBytes)}。${p.hasSystemPkg ? (p.systemPresent && !p.replaceSystem ? '设备已有 Android 系统，本次不覆盖。' : '包含 Android 系统包（解包到 /home）。') : '载荷不含系统包，沿用设备上已有的。'}</p>
    <p class="hint">写入位置：/boot 里新增 android 内核（出厂内核链接不动）、/lib/modules 新增一个模块目录、/usr/bin 四个宿主程序、/sbin/init 换成带回落的包装脚本（原链接备份为 /sbin/init.systemd-orig）。Android 系统与数据在 /home，重启不切槽。</p>
    <details><summary>文件清单</summary><pre class="files">${(p.files ?? []).map((f) => esc(f)).join('\n')}</pre></details>
  `
}

function appendLog(line: string) {
  const el = document.querySelector('#log') as HTMLPreElement | null
  if (!el) return
  el.textContent += line + '\n'
  el.scrollTop = el.scrollHeight
}

function setBusy(b: boolean) {
  state.busy = b
  const log = ($('#log') as HTMLPreElement).textContent
  render()
  ;($('#log') as HTMLPreElement).textContent = log
  ;($('#log') as HTMLPreElement).scrollTop = 1e9
}

async function guarded(fn: () => Promise<void>) {
  if (state.busy) return
  setBusy(true)
  try {
    await fn()
  } catch (e) {
    appendLog('✗ ' + String(e))
  } finally {
    try { state.info = (await Probe()) as Info } catch { /* 设备可能已重启 */ }
    setBusy(false)
  }
}

function bind() {
  $('#host')?.addEventListener('change', async (e) => {
    const host = (e.target as HTMLInputElement).value.trim()
    const saved = await LoadPassword(host)
    if (saved) { state.password = saved; ($('#password') as HTMLInputElement).value = saved; appendLog('已从钥匙串读到 ' + host + ' 的密码') }
  })
  $('#chk-remember')?.addEventListener('change', (e) => { state.remember = (e.target as HTMLInputElement).checked })
  $('#btn-forget')?.addEventListener('click', async () => { await ForgetPassword(($('#host') as HTMLInputElement).value); state.password = ''; render() })
  $('#btn-connect')?.addEventListener('click', async () => {
    const host = ($('#host') as HTMLInputElement).value
    const pw = ($('#password') as HTMLInputElement).value
    state.password = pw
    if (!pw) { appendLog('请先填 SSH 密码') }
    try {
      state.info = (await Connect(host, pw, state.remember)) as Info
      if (state.info.modelKey !== 'rmppm') state.action = 'rmkit'
      render()
    } catch (e) { appendLog('✗ ' + String(e)) }
  })
  $('#btn-disconnect')?.addEventListener('click', async () => { await Disconnect(); state.info = null; render() })
  $('#btn-probe')?.addEventListener('click', async () => { try { state.info = (await Probe()) as Info; render() } catch (e) { appendLog('✗ ' + String(e)) } })
  document.querySelectorAll<HTMLButtonElement>('.tab').forEach((t) => t.addEventListener('click', () => { state.action = t.dataset.action as Action; render() }))
  $('#btn-choose')?.addEventListener('click', async () => { try { const b = (await ChooseBundle()) as BundleInfo | null; if (b) { state.bundle = b; render() } } catch (e) { appendLog('✗ ' + String(e)) } })
  $('#proxy')?.addEventListener('change', (e) => { state.proxy = (e.target as HTMLInputElement).value.trim(); try { localStorage.setItem('proxy', state.proxy) } catch { /* 忽略 */ } })
  $('#btn-download')?.addEventListener('click', () => guarded(async () => {
    const name = state.action === 'rmkit' ? 'rmkit-cn-bundle.zip' : 'android-rmppm-bundle.zip'
    state.proxy = (($('#proxy') as HTMLInputElement)?.value || '').trim()
    $('#dl-progress').classList.remove('hidden')
    state.bundle = (await DownloadBundle(RELEASE_BASE + name, '', state.proxy)) as BundleInfo
  }))
  $('#chk-replace')?.addEventListener('change', (e) => { state.replaceSystem = (e.target as HTMLInputElement).checked })
  $('#chk-removedata')?.addEventListener('change', (e) => { state.removeData = (e.target as HTMLInputElement).checked })
  $('#btn-plan')?.addEventListener('click', async () => {
    try {
      if (state.action === 'rmkit') $('#plan').innerHTML = renderRmkitPlan((await PlanRmkit()) as RmkitPlan)
      else $('#plan').innerHTML = renderAndroidPlan((await PlanAndroid(state.replaceSystem)) as AndroidPlan)
    } catch (e) { $('#plan').innerHTML = `<p class="error">✗ ${esc(String(e))}</p>` }
  })
  $('#btn-run')?.addEventListener('click', async () => {
    if (state.action === 'android') {
      const p = (await PlanAndroid(state.replaceSystem).catch((e) => { appendLog('✗ ' + String(e)); return null })) as AndroidPlan | null
      if (!p) return
      if ((p.blockers ?? []).length) { $('#plan').innerHTML = renderAndroidPlan(p); return }
    }
    const what = state.action === 'rmkit' ? 'rmkit-cn' : '单槽 Android'
    if (!(await Confirm('确认', `确定要在这台设备上安装 ${what} 吗？安装过程中请不要拔线。`))) return
    guarded(async () => { if (state.action === 'rmkit') await RunRmkit(); else await RunAndroid(state.replaceSystem) })
  })
  $('#btn-uninstall')?.addEventListener('click', async () => { if (await Confirm('确认', '确定卸载 rmkit-cn？设备会恢复出厂启动配置。')) guarded(() => UninstallRmkit()) })
  $('#btn-uninstall-android')?.addEventListener('click', async () => { if (await Confirm('确认', state.removeData ? '确定卸载 Android 并删除 /home 里的系统与数据？' : '确定卸载 Android（保留 /home 数据）？')) guarded(() => UninstallAndroid(state.removeData)) })
  $('#btn-boot-android')?.addEventListener('click', async () => { if (await Confirm('确认', '设备将重启进入 Android，约 1 到 3 分钟。回来时可在 Android 桌面点“原厂系统”。继续？')) guarded(() => BootAndroid()) })
  $('#btn-stock')?.addEventListener('click', () => guarded(() => ReturnToStock()))
  $('#btn-diag')?.addEventListener('click', async () => {
    try { const t = await DiagnoseAndroid(); appendLog('===== Android 启动诊断 =====\n' + t + '===== 诊断结束 (已保存到日志目录, 请把该文件发给开发者) =====') } catch (e) { appendLog('✗ ' + String(e)) }
  })
  $('#btn-reset-data')?.addEventListener('click', async () => { if (await Confirm('确认', '清空 Android 的全部应用与设置？下次进 Android 会重新首次开机（约 5 分钟）。')) guarded(() => ResetAndroidData()) })
  $('#btn-apks')?.addEventListener('click', async () => {
    let paths: string[] = []
    try { paths = (await ChooseAPKs()) || [] } catch (e) { appendLog('✗ ' + String(e)); return }
    if (!paths.length) return
    guarded(() => InstallAPKs(paths))
  })
  $('#btn-cancel')?.addEventListener('click', () => Cancel())
  $('#btn-logdir')?.addEventListener('click', () => OpenLogDir())
}

EventsOn('log', (line: string) => appendLog(line))
EventsOn('progress', (p: { done: number; total: number }) => {
  const bar = document.querySelector('#dl-progress div') as HTMLElement | null
  if (bar && p.total > 0) bar.style.width = Math.min(100, (p.done / p.total) * 100).toFixed(1) + '%'
})

try { state.proxy = localStorage.getItem('proxy') || '' } catch { /* 忽略 */ }
render()
LoadPassword('10.11.99.1').then((pw) => { if (pw) { state.password = pw; render(); appendLog('已从钥匙串读到保存的密码') } })
LogDir().then((d) => appendLog('审计日志目录: ' + d))
if (!state.proxy) DetectProxy().then((p) => { if (p) { state.proxy = p; appendLog('探测到代理: ' + p); render() } })
