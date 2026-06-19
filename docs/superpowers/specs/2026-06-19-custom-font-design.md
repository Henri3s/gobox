# 自定义字体 · 设计文档

- **日期**：2026-06-19
- **分支**：`feat/custom-font`（从 `feat/auto-tidy` 分叉）
- **状态**：设计已确认，进入实现

## 1. 目标

在侧栏底部「中英文切换」按钮旁，新增**字体选择器**，让用户能用自己的字体（尤其开发者装的各种等宽字体），而不是被 SF Pro / SF Mono 锁死。自定义字体对 **App 界面** 和 **终端/编辑器** 都生效。

## 2. 理解摘要

- **要做什么**：在 `.sidebar-foot`（`#lang-toggle` 旁）加字体选择器，可切换界面字体与代码字体
- **为什么**：让用户用自己的字体，不被系统字体锁死
- **给谁用**：个人 macOS 桌面 App 用户，优先列出**自己安装的字体**
- **关键约束**：粒度=双字体；清单=Electron 枚举真实系统字体；UI=自定义 popover；注册=纯 CSS 字体名引用
- **非目标**：不做字号/粗细/行高调整；不做字体预览窗口；不做 Windows/Linux 适配

## 3. 假设

1. 字体名引用在 Electron 下可靠（用户装的字体 Chromium 能识别）；某字体回退则作为后续 issue 单独处理
2. 持久化用现有 `config.json`，新增字段 `fontUI` / `fontMono`
3. 浏览器模式（`node server.js`）拿不到系统字体，退化为硬编码预设清单
4. popover 单实例，同时只开一个
5. 字体切换不需要重启，所有已存在的 xterm session 和 Monaco editor 就地重渲染

## 4. 决策日志

| # | 决策 | 备选 | 理由 |
|---|------|------|------|
| D1 | 字体粒度=双字体（界面比例 + 代码等宽） | A 单字体 / C 4 字体独立 | 符合 macOS 双字体传统，覆盖诉求又不臃肿 |
| D2 | 清单=白名单优先 + 用户字体优先 | A 全系统 / B 等宽比例过滤 | 用户要自己装的字体；白名单兜底 |
| D3 | UI=自定义 popover + 字体自渲染名字 | A 原生 select / C 分段控件 | 所见即所得；与 cmdk/shot-card 风格统一 |
| D4 | 来源=Electron 枚举系统真实字体 | B 硬编码 / C 合并 | 用户要真实字体；浏览器模式退回预设 |
| D5 | 注册=纯 CSS 字体名引用 | B @font-face | 零额外文件；Chromium 能识别用户字体 |
| D6 | 触发器=双药丸（Aa 字 / Aa 码） | B 单入口+内部分段 | 视觉三联；两角色始终可见 |
| D7 | 药丸文字=Aa + popover 带搜索框 | — | 用户确认 |
| D8 | UI 模式允许选等宽，mono 模式不防呆 | UI 隐藏等宽 / mono 禁选比例 | 不设多余限制 |
| D9 | 字体跟随用户，不跟随皮肤 | display/fname 跟随皮肤 | 用户确认：自定义字体完全交给用户 |
| D10 | 未选字体时不注入覆盖 | 强制注入默认 | 维持现状默认；主动选才覆盖 |
| D11 | 重渲染用热改，不销毁重建 | 销毁重建 | xterm `options.fontFamily` + Monaco `updateOptions` 支持热改 |
| D12 | 回放器已打开录像不强制重刷 | 全量重刷 | 新建回放自然读到新字体 |
| D13 | 等宽判定=CoreText 精确判定（font-list 的 `getFonts2().monospace`） | 关键词正则启发 | `font-list` 预编译 universal binary，调 NSFontManager trait mask 精确判定；废弃启发式 |
| D14 | 持久化=localStorage + config.json | 仅 localStorage | 仿 `/api/lang` 双写 |
| D15 | 新增 npm 依赖 `font-list` | system_profiler / native binding | 专为 Electron 字体枚举而生 |

## 5. 设计

### 5.1 架构总览

```
electron/main.js  ──fontList.getFonts()──▶  IPC 'fonts:list'
                                                  │
                       preload.js: window.fanboxFont.list()
                                                  │
                public/app.js: 启动调用，缓存 state.fontList
                                                  │
                applyFont('ui'|'mono', name) ──▶ 注入 CSS 变量
                                                  │
                                  ┌───────────────┴───────────────┐
                                  ▼                               ▼
                        term.refont()                    mona.refont()
                     (xterm 热改字体)               (Monaco updateOptions)

浏览器模式（node server.js）：
  GET /api/fonts  ──▶ 硬编码预设清单（kind: 'preset'）
  POST /api/font  ──▶ updateConfig({ fontUI | fontMono })
```

### 5.2 DOM 结构（index.html）

```html
<div class="sidebar-foot">
  <span class="sidebar-foot-text">本地运行 · 数据不出本机</span>
  <div class="foot-toggles">
    <a id="font-ui-btn"   class="lang-toggle font-toggle" title="界面字体">Aa</a>
    <a id="font-mono-btn" class="lang-toggle font-toggle" title="代码字体（终端 / 编辑器）">Aa</a>
    <a id="lang-toggle" class="lang-toggle"></a>
  </div>
</div>
<!-- body 末尾：popover 单实例 -->
<div id="font-popover" class="font-popover hidden" role="dialog">
  <div class="font-pop-head">
    <span class="font-pop-title">界面字体</span>
    <button class="font-pop-reset" title="恢复默认">↺</button>
  </div>
  <div class="font-pop-search"><input type="text" placeholder="搜索字体…" id="font-pop-q"></div>
  <ul class="font-pop-list" id="font-pop-list"></ul>
</div>
```

### 5.3 字体清单数据结构

```js
[
  { name: "JetBrains Mono",  fixed: true,  kind: "user" },     // 用户装的等宽
  { name: "MesloLGS NF",     fixed: true,  kind: "user" },     // Nerd Font
  { name: "PingFang SC",     fixed: false, kind: "system" },   // 系统比例
  { name: "SF Mono",         fixed: true,  kind: "system" }    // 系统等宽
]
```

- `fixed`：等宽标记（`font-list` 不提供 → 用关键词正则启发：`/mono|nerd|code|courier|menlo|consol/i`）
- `kind`：`user`（路径在 `~/Library/Fonts`）排前，`system` 排后，`preset`（浏览器模式兜底）排最后

### 5.4 列表项渲染

```html
<li class="font-item" data-name="JetBrains Mono"
    style="font-family: 'JetBrains Mono', sans-serif">
  <span class="font-item-name">JetBrains Mono</span>
  <span class="font-item-tag">代码</span>     <!-- fixed 才显示 -->
  <span class="font-item-check">✓</span>      <!-- active 才显示 -->
</li>
```

**列表分组**：在 user/system/preset 分组前加 `.font-group-label`（灰色小标题）。

**过滤规则**（按 mode）：
- `mode === 'ui'`：比例优先，**不隐藏**等宽。排序：比例 user → 比例 system → 等宽 user → 等宽 system
- `mode === 'mono'`：等宽优先，**不防呆**禁选比例。排序：等宽 user → 等宽 system → 比例

### 5.5 CSS 变量注入（app.js）

未选字体时不注入覆盖，维持 `:root` 默认。用户主动选后注入（用户字体放最前，原回退链在后）：

```js
applyFont('ui', name):
  --font-ui      = `"${name}", -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif`
  --font-display = 同 --font-ui
  --font-fname   = 同 --font-ui

applyFont('mono', name):
  --font-mono = `"${name}", ui-monospace, "SF Mono", Menlo, monospace`
  --font-term = `"${name}", "JetBrainsMono Nerd Font", "MesloLGS NF", ui-monospace, monospace`
```

**注意**：`--font-display` 和 `--font-fname` 也跟随用户字体（D9）——一旦设了字体，4 套皮肤只剩颜色差异。

### 5.6 重渲染难点（term.refont / mona.refont）

xterm 和 Monaco 在创建时一次性读字体，`retheme()` 只换 theme 不换字体。新增热改方法：

```js
// term（app.js retheme 旁）
refont() {
  const ff = getComputedStyle(document.documentElement).getPropertyValue('--font-term').trim() || 'monospace';
  this.sessions.forEach((s) => { s.xterm.options.fontFamily = ff; s.fit?.fit(); });
}

// mona（app.js retheme 旁）
refont() {
  const ff = getComputedStyle(document.documentElement).getPropertyValue('--font-mono').trim() || 'monospace';
  if (this.editor) this.editor.updateOptions({ fontFamily: ff });
  if (this.diffEditor) this.diffEditor.updateOptions({ fontFamily: ff });
}
```

**覆盖点**：
- `app.js:1301/1440/4131` Monaco 创建——首次创建靠 `applyPersistedFont` 提前注入读到新值
- `app.js:2955/3445` xterm 创建——同上
- 回放器已打开录像**不强制重刷**（D12），新建回放自然读到新值

### 5.7 IPC / API

**electron/main.js**：
```js
const fontList = require('font-list');
ipcMain.handle('fonts:list', async () => {
  try {
    const names = await fontList.getFonts({ disableQuoting: true });
    const FIXED_HINT = /mono|nerd|code|courier|menlo|consol/i;
    return names.map((name) => ({
      name,
      fixed: FIXED_HINT.test(name),
      kind: isUserFont(name) ? 'user' : 'system',
    }));
  } catch { return []; }
});
```

**preload.js**：
```js
contextBridge.exposeInMainWorld('fanboxFont', {
  list: () => ipcRenderer.invoke('fonts:list'),
});
```

**server.js**：
```js
// GET /api/fonts —— 浏览器模式兜底（Electron 走 IPC 不走这里）
const PRESET_FONTS = [
  { name: 'JetBrains Mono', fixed: true,  kind: 'preset' },
  { name: 'Fira Code',      fixed: true,  kind: 'preset' },
  { name: 'SF Mono',        fixed: true,  kind: 'preset' },
  { name: 'Menlo',          fixed: true,  kind: 'preset' },
  { name: 'PingFang SC',    fixed: false, kind: 'preset' },
  // 约 10 个
];

// POST /api/font —— 仿 /api/lang 持久化
if (p === '/api/font' && req.method === 'POST') {
  const b = await readBody(req);
  await updateConfig((c) => {
    if (b.mode === 'ui' || b.mode === 'mono') c['font' + cap(b.mode)] = b.name || '';
  });
  return sendJSON(res, 200, { ok: true });
}
```

### 5.8 CSS 样式（style.css）

复用现有变量，4 套皮肤自动适配：

```css
.font-toggle { /* 继承 .lang-toggle 全部样式 */ }
.foot-toggles { display: flex; gap: 4px; align-items: center; }

.font-popover {
  position: fixed; z-index: 400;
  width: 280px; max-height: 360px;
  background: var(--bg-2); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow);
  display: flex; flex-direction: column; overflow: hidden;
  animation: shotIn 0.18s ease;
}
[data-theme="macos"] .font-popover {
  backdrop-filter: blur(20px) saturate(180%); background: var(--panel);
}

.font-pop-head { display: flex; justify-content: space-between; align-items: center;
  padding: 8px 10px; border-bottom: 1px solid var(--border); }
.font-pop-title { font-size: 11px; color: var(--text-faint);
  text-transform: uppercase; letter-spacing: 1px; }
.font-pop-reset { background: none; border: none; color: var(--text-dim);
  cursor: pointer; font-size: 13px; }
.font-pop-reset:hover { color: var(--accent); }

.font-pop-search { padding: 6px 10px; border-bottom: 1px solid var(--border); }
.font-pop-search input { width: 100%; background: var(--bg-3);
  border: 1px solid var(--border); border-radius: 6px;
  color: var(--text); padding: 4px 8px; font-size: 12px; }

.font-pop-list { list-style: none; overflow-y: auto; padding: 4px 0; }
.font-group-label { font-size: 10px; color: var(--text-faint);
  text-transform: uppercase; letter-spacing: 1px; padding: 6px 12px 2px; }
.font-item { display: flex; align-items: center; gap: 8px;
  padding: 6px 12px; cursor: pointer; font-size: 13px; color: var(--text); }
.font-item:hover { background: var(--bg-3); }
.font-item.active { background: var(--accent-soft); }
.font-item-name { flex: 1; }
.font-item-tag { font-size: 9px; color: var(--accent);
  border: 1px solid var(--accent); border-radius: 3px; padding: 0 4px; }
.font-item-check { color: var(--accent); font-size: 12px; }
.font-pop-empty { padding: 20px; text-align: center;
  color: var(--text-faint); font-size: 12px; }
```

## 6. 关键风险

1. **字体名引用可能失效**：少数用户字体 Chromium 识别不到 → 回退。实测发现再加 `@font-face` 兜底（增量改造）。
2. **`font-list` 首次调用慢**（200-500ms）：App 启动后**异步预热**，不阻塞首屏。
3. **xterm WebGL 换字体**：glyph atlas 缓存问题。`refont()` 后调 `fit()` 触发重绘，实测验证。

## 7. 实现顺序

1. electron/main.js + font-list 依赖（IPC `fonts:list`）
2. server.js（`/api/fonts` + `/api/font`）
3. preload.js（fanboxFont 桥接）
4. app.js（applyFont + refont + popover 逻辑）
5. index.html + style.css（DOM + 样式）
6. 验证：启动测试 + 字体切换 + 终端/编辑器重渲染
