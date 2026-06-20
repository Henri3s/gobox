# 设计文档：自动整理规则引擎（Auto-Tidy）

- **日期**: 2026-06-15
- **分支**: `feat/auto-tidy`（基于 `master`，master 只做同步上游）
- **作者**: brainstorming 产出
- **状态**: 待实现

## 一、背景与定位

gobox（fork 自 `alchaincyf/fanbox`）已有一个「AI 整理」功能：`/api/organize/launch` 拉起一个 claude/codex CLI 会话，**交互式、人审批驱动**——agent 提议、用户对话确认后才移动文件，带回滚日志。

本次新增的「自动整理」（Auto-Tidy）与之**互补**，定位不同：

| | AI 整理（现有） | 自动整理（新增） |
|---|---|---|
| 触发 | 一次性、手动启动 | 持续、定时扫描 |
| 判断 | AI 语义判断 | 确定性规则匹配 |
| 适用 | 「帮我收拾一下整个下载文件夹」 | 「截图永远自动进截图文件夹」 |

参考目标工具：macOS 上的 [Hazel](https://www.noodlesoft.com/)（folder watcher + rules + actions 的成熟范式）。

## 二、需求

**用户故事**：配置「规则集」（选一个源文件夹 + 多条规则），系统定时扫描源文件夹，把匹配规则的文件**直接移动**到目标文件夹，全程记回滚日志，可一键撤销。

需求决策（来自 brainstorming 对话）：

1. **触发方式**：定时扫描（非实时监听、非纯手动）。
2. **条件描述**：规则编辑器（下拉/输入框组合的预定义条件，非 glob、非 AI 语义）。
3. **规则结构**：每源多规则——一个规则集 = 一个源文件夹 + N 条规则，每条独立开关。
4. **执行模式**：扫描后**直接移动** + 可回滚（非预览确认）。
5. **调度模型**：参考 Hazel 最佳实践——应用开启时后台定时器生效，应用关闭时不工作（与现有 AI 整理一致，符合「驾驶舱开着才工作」的定位）。
6. 功能 2（自定义大模型 API）不在本次范围——fanbox 现有 AI 整理已覆盖该需求。

## 三、数据模型

复用现有 `~/.fanbox/config.json`，新增 `autoTidy` 字段。通过项目现有的 `updateConfig()`（串行化读-改-写 + 原子写）持久化。

```jsonc
{
  "autoTidy": {
    "rulesets": [
      {
        "id": "rs_1718000000123",
        "name": "下载文件夹分类",
        "enabled": true,
        "source": "~/Downloads",
        "intervalMin": 30,           // 扫描间隔，分钟；0 = 仅手动触发
        "rules": [
          {
            "id": "r_1",
            "enabled": true,
            "field": "extension",
            "op": "is",
            "value": "png",
            "target": "~/Pictures/截图"
          },
          {
            "id": "r_2",
            "enabled": true,
            "field": "nameContains",
            "op": "contains",
            "value": "截屏",
            "target": "~/Pictures/截图"
          },
          {
            "id": "r_3",
            "enabled": true,
            "field": "olderThan",
            "op": "days",
            "value": 30,
            "target": "~/Downloads/_archive"
          }
        ],
        "lastRun": 0,                // 最后一次扫描时间戳（毫秒）
        "lastSummary": "",           // 最后一次扫描结果一句话摘要（供 UI 显示）
        "lastLog": ""                // 最近一次执行写入的回滚日志文件名（撤销用）
      }
    ]
  }
}
```

### 条件类型（field / op / value）

| field | op | value 类型 | 例子 | 说明 |
|---|---|---|---|---|
| `extension` | `is` / `isNot` | 字符串（后缀，无点） | `png` | 后缀匹配 |
| `nameContains` | `contains` / `notContains` | 字符串 | `截屏` | 文件名子串 |
| `olderThan` | `days` | 数字 | `30` | 修改时间早于 N 天前 |
| `biggerThan` | `mb` | 数字 | `100` | 文件大小大于 N MB |
| `kind` | `is` | 枚举 | `image` | 文件类型组（见下方映射） |

`kind` 枚举到后缀的映射（匹配时不区分大小写）：

| kind | 后缀 |
|---|---|
| `image` | png jpg jpeg gif webp heic heif tiff bmp svg |
| `video` | mp4 mov m4v avi mkv webm flv wmv |
| `audio` | mp3 m4a aac wav flac ogg opus |
| `doc` | pdf doc docx xls xlsx ppt pptx txt md pages key numbers |
| `archive` | zip rar 7z tar gz bz2 xz |

### 匹配规则

- 规则**按数组顺序**从上到下匹配，一个文件命中第一条 `enabled` 规则即停止（避免同一文件被多条规则重复移动）。
- 未命中任何规则的文件保持不动。

## 四、运行机制（扫描调度）

**采用方案 A：轻量内存调度器。**

- Electron 主进程（`electron/main.js`）启动时，读取 config 中所有 `enabled && intervalMin > 0` 的规则集，各自注册一个 `setInterval` 定时器。
- 定时器到点 → 调用 `autoTidyRun(rulesetId)` → 扫描源目录 → 逐文件匹配规则 → 命中则移动（复用现有 `movePath()`）→ 写回滚日志 → 更新 `lastRun`/`lastSummary`。
- 应用退出 / 规则集被禁用 / 间隔被改时，清理对应定时器。
- 支持手动「立即扫描一次」（不依赖定时器）。

**为何不用系统级后台任务（launchd）**：侵入系统、权限复杂、与 Electron 架构割裂、调试难。对增强功能过重。应用开启才生效与现有 AI 整理一致，符合产品定位。

### 扫描流程

```
autoTidyRun(rulesetId)
  ├─ 读 ruleset（enabled=false 直接返回）
  ├─ fsp.readdir(source, { withFileTypes: true })
  ├─ 过滤：只处理文件（跳过目录）、跳过隐藏文件（以 . 开头）
  ├─ 对每个候选文件：
  │    ├─ 逐条匹配 enabled 规则
  │    ├─ 命中第一条 → 调 movePath(file, rule.target)
  │    └─ 记录 { from, to, rule } 进本批 moves
  ├─ 若 moves 非空 → 写回滚日志 JSON 到 ~/.fanbox/organize-log/<ts>.json
  └─ 更新 ruleset.lastRun / lastSummary
```

## 五、移动与回滚（安全机制）

### 移动

直接复用 `server.js` 中已有的 `movePath()`（`server.js:902`）：

- 同卷 `rename`、跨卷 `EXDEV` 回退 `copyFile + unlink`
- 目标目录不存在先 `mkdir -p`
- 同名文件自动加序号（`name-2.ext`）防覆盖

**不另写文件操作逻辑**，保持一致性。

### 回滚日志

复用现有 `~/.fanbox/organize-log/` 的 JSON 格式约定（与 AI 整理共用同一日志目录），新增 `source` 字段标识来源：

```json
{
  "dir": "~/Downloads",
  "at": 1718000000000,
  "source": "auto-tidy",
  "ruleset": "下载文件夹分类",
  "moves": [
    { "from": "/abs/from.png", "to": "/abs/to.png", "rule": "png → ~/Pictures/截图" }
  ]
}
```

每次执行（定时或手动）写一个新日志文件。

「撤销」的粒度是**单个规则集的最近一次执行**（非全局）：每个规则集记住自己最近一次写入的日志文件名（存在 ruleset 的 `lastLog` 字段），UI 的「撤销最近一次」读该日志，逐条把 `to` 移回 `from`（`from` 位置已被占用的跳过并在 UI 说明）。总览 modal 里每个规则集各有自己的撤销入口。

### 保护性约束

1. **只处理文件，不碰文件夹**（与现有 AI 整理约定一致）。
2. **隐藏文件（以 `.` 开头）跳过**。
3. **目标目录是源目录自身或其子目录时跳过该条移动**（防止递归移动自己 / 无意义操作）。
4. 单条移动失败记错误、继续，不中断整批；失败信息汇总进 `lastSummary`。

## 六、UI 设计

现有 UI 结构：顶部 `#topbar`（面包屑 + 排序/视图按钮）、左侧 `#sidebar`（快速入口 / 收藏 / Agent 项目 / skills / usage）、主体（文件区 + 预览 + 终端）。功能入口均为 modal 或 sidebar 项，无独立「设置页」。

### 入口（方案 B：双入口）

**主入口——右键菜单**（与现有「AI 整理…」并列）：

- 文件区空白菜单 + 文件夹右键菜单新增 `⚡ 自动整理此文件夹…`
- 点击 → 弹出规则配置 modal，源文件夹默认填当前目录

**管理入口——侧边栏底部**：

- 在 sidebar 底部（skills / usage 同区）加 `🔄 自动整理` 链接
- 点击 → 弹出规则集总览 modal：列出所有规则集、每条带开关、间隔、最近执行摘要、「撤销最近一次」、「立即扫描」、编辑、删除

### 规则配置 modal 交互

```
┌─ 自动整理规则集 ──────────────────────────── ✕ ┐
│ 名称  [下载文件夹分类        ]   ☑ 启用          │
│ 源    [~/Downloads         ] [选择]             │
│ 间隔  [30] 分钟（0=仅手动）    [立即扫描一次]    │
│                                                  │
│ 规则（从上到下匹配，命中即停）：                  │
│ ┌────────────────────────────────────────────┐  │
│ │ [扩展名▾] [是▾] [png    ] → [~/Pictures/截图]│ ✕│
│ │ [名称包含▾] [包含▾] [截屏 ] → [~/Pictures/截图]│ ✕│
│ │ [早于▾] [天▾] [30     ] → [~/Downloads/_archive]│ ✕│
│ └────────────────────────────────────────────┘  │
│ ＋ 添加规则                                       │
│                                                  │
│ 最近：2026-06-15 14:30 移动 5 个，撤销            │
│                            [取消]  [保存]         │
└──────────────────────────────────────────────────┘
```

- 规则行可删除（✕）、新增（＋）。
- 字段下拉决定后续操作符和值输入类型（后缀=文本输入；天数/MB=数字输入；kind=枚举下拉）。
- 底部显示最近一次执行摘要 + 撤销入口。

## 七、文件改动清单

遵循项目现有「单文件 `server.js` + `app.js`」风格，**不拆分新文件**，不引入新依赖，不改现有 AI 整理代码。

| 位置 | 改动 | 预估行数 |
|---|---|---|
| `server.js` | 新增 `autoTidyMatch(file, rules)`、`autoTidyRun(id)`；HTTP 端点 `/api/autotidy/list`、`/save`、`/run`、`/undo` | +200 |
| `electron/main.js` | 应用启动时读 config 注册定时器；规则集增删改/启停时通过 IPC 通知主进程重排定时器；退出时清理 | +60 |
| `public/app.js` | 规则配置 modal 渲染、规则行增删、右键菜单项、侧栏管理入口、撤销交互、定时器状态回显 | +350 |
| `public/style.css` | modal、规则行、侧栏链接样式 | +80 |
| `public/index.html` | modal 容器、侧栏入口若干空 div | +8 |

## 八、Fork 同步工作流（SOP）

仓库关系：`origin = Henri3s/gobox`（自己的，要 push 共享），`upstream = alchaincyf/fanbox`（上游，频繁更新）。

**策略：全程使用 merge，永不 force push。** 因功能最终共享给他人使用，改写历史（rebase 会改 hash）会让任何已 clone / 提 PR 的人本地记录错乱；merge 只增不改，对共享最安全。

分支约定：

```
master        ← 只做两件事：同步上游（merge）、接收成熟功能（merge）。永不直接写功能、永不 force push。
└─ feat/auto-tidy  ← 自动整理功能开发分支
```

### 一次性配置（已完成）

```bash
git remote add upstream https://github.com/alchaincyf/fanbox.git
git fetch upstream
```

### 同步上游更新（上游频繁更新时）

```bash
git checkout master
git fetch upstream
git merge upstream/master        # merge，不改写历史
git push origin master           # 推到自己的 fork

git checkout feat/auto-tidy
git merge master                 # 把上游更新带到功能分支
# 若有冲突，正常解决冲突 → git add → git commit
```

### 发功能给大家用

```bash
git checkout feat/auto-tidy
git push origin feat/auto-tidy
gh pr create --base master --head feat/auto-tidy   # 在自己 fork 内发 PR
# 评审通过后 merge 进 master，大家 pull master 即可用
```

### 后续新功能

每个独立功能开自己的分支 `feat/<name>`，从最新 master 切出，开发完 merge 回 master。保持功能分支彼此独立，便于单独评审与回滚。

## 九、不在本次范围（YAGNI）

- 实时监听（chokidar / fs.watch）——定时扫描已够用。
- glob / 正则条件——规则编辑器的预定义条件已覆盖常见场景。
- AI 语义判断条件——现有 AI 整理已覆盖，自动整理走确定性规则。
- launchd 系统级后台——应用开启才生效，符合产品定位。
- 功能 2（自定义大模型 API 接入）——fanbox 现有 AI 整理已覆盖。
- 规则导入/导出、规则模板——首版不做，需要再说。

## 十、验收标准

1. 可在 UI 创建规则集（命名、选源、设间隔）、增删规则行、保存。
2. 「立即扫描一次」能按规则移动匹配文件，未命中的不动。
3. 定时器在应用开启、规则集启用、间隔 > 0 时按设定间隔自动扫描。
4. 同名文件加序号、跨卷 copy+delete、隐藏文件跳过、目录跳过均符合预期。
5. 「撤销最近一次」能将上次移动的文件逐条移回原位。
6. 重启应用后规则集与定时器状态保持（从 config 恢复）。
7. master 始终可同步上游，功能分支可 merge 进 master，全程无 force push。
