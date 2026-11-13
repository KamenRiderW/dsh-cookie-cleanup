# DSH Cookie 清理工具使用手册

文档版本：2026-11-12（对应本次安全与健壮性修复后的脚本）

适用对象：日常使用者、负责维护/排查该工具的人。

本文是参数、退出码和行为的权威；README 只做机制概览和快速开始。

配套文档：

- `README.md`：工具原理、DSH 为什么会产生大量 Cookie、上游修复建议。
- `CHANGELOG.md`：每次行为变化和修复记录。**排查新问题前先看最近一次变更。**
- `AGENTS.md`：维护/agent 导航（文档入口、检查命令、测试副作用）。
- `CODING_STANDARDS.md`：review 阶段的判断题标准。
- `MANUAL.md`：本文件，使用、参数、排障流程和诊断命令。

---

## 1. 工具概览

### 1.1 它解决什么问题

DSH Desktop 每次启动都用 `--port 0` 启动本地 Host，Cookie 名由 `host:port`
哈希得到，因此每次启动都会新增一个 `dsh-auth-*` Cookie，30 天后才过期。
累计约 68～71 个后，Cookie 请求头超过 Node 默认的 16 KiB，Host 返回
`431 Request Header Fields Too Large`，表现为启动失败。

本工具只做一件事：在 DSH 完全退出、Cookie 数据库可写时，删除
`127.0.0.1` 下名字以 `dsh-auth-` 开头的行，并在删除前生成一致性备份。

### 1.2 它不会做什么

- 不退出账号：`dsh-auth-*` 是本地 Host 的每次启动会话 Cookie；账号凭据在
  `~\.dsh\.credentials.yaml`，脚本不碰。
- 不删除其他站点/其他 host 的 Cookie；只处理 `host_key = 127.0.0.1` 且
  大小写精确匹配 `dsh-auth-` 前缀的行。
- 不删除聊天记录、记忆、知识库、设置。
- 不修改 `app.asar` 或应用安装文件。
- 不在应用运行时强行改数据库（唯一例外是显式 `-KillApp`：先结束进程再清理，
  会中断进行中的任务）。

### 1.3 关键限制

- 应用必须**完全退出**（托盘图标退出，任务管理器里没有
  `DeepSeek Harness.exe`）；Electron 运行时独占锁定 Cookie 数据库。
- 本工具是上游 bug 的缓解，不是根治。DSH 修复 Cookie 命名机制前，
  新 Cookie 会持续产生。
- Windows 专用；依赖 PowerShell 5.1+ 和 Python 3（含 `sqlite3` 标准库）。

---

## 2. 环境与依赖

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10/11（脚本使用 PowerShell、计划任务、`icacls`） |
| PowerShell | Windows PowerShell 5.1 或 PowerShell 7 |
| Python | Python 3，带 `sqlite3` 标准库 |
| Windows Script Host | 计划任务/Startup 的隐藏启动；WSH 被禁用时任务回退直接 PowerShell，Startup 不可用 |
| 权限 | 普通用户即可；计划任务使用 `RunLevel Limited`，不需要管理员 |
| 应用状态 | 手动清理/恢复时必须完全退出 DSH |

### 2.1 脚本如何找 Python

顺序如下，找到第一个可用项：

1. 环境变量 `DSH_COOKIE_CLEANUP_PYTHON` 指向的 `python.exe`。
2. `%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe`。
3. `PATH` 中的 `python.exe`、`python`、`python3.exe`、`python3`。
4. `py.exe`。

Microsoft Store 的 `WindowsApps\python.exe` 转发器会被跳过，避免“打开商店”
式误报。需要提前验证时加 `-CheckPython`；日志会带上实际 Python 路径和
stderr，不只是在报错里写“无法读取”。

### 2.2 脚本如何找 DSH 可执行文件

`-StartApp` 时按以下顺序：

1. 显式 `-AppExe`（必须是存在的文件，否则报错）。
2. 环境变量 `DSH_DESKTOP_EXE`（必须是存在的文件，否则报错）。
3. 脚本目录上两级的 `DeepSeek Harness\DeepSeek Harness.exe` 或
   `DeepSeek Harness.exe`。
4. 正在运行的 `DeepSeek Harness` 进程路径。

---

## 3. 文件与目录布局

| 路径 | 用途 |
| --- | --- |
| `cleanup.ps1` | 主脚本：进程检查、备份、清理、监视、恢复 |
| `cleanup_db.py` | 只做 SQLite 读写：统计、备份、删除、校验 |
| `dsh-cookie-cleanup.cmd` | 双击手动清理 |
| `dsh-cookie-report.cmd` | 双击只读报告（`-DryRun`） |
| `start-dsh-clean.cmd` | 先清理再启动 DSH |
| `install-autoclean.cmd` | 双击安装并立即启动自动清理 |
| `remove-autoclean.cmd` | 双击卸载自动清理 |
| `install-task.ps1` | 安装/停止/卸载/查看自动清理 |
| `tests\check.ps1` | Fast/Full 检查：语法、help 覆盖、控制台断言扫描、测试套件 |
| `tests\run-tests.ps1` | 自测套件（由 `check.ps1` 调用）：恢复/回滚、host 过滤、锁分类、日志/备份轮转、exit 3、ACL、包装器、协作停止、watcher 归属、计划任务启停（临时任务，结束后注销） |
| `tests\resolve-python.ps1` | 测试/检查共用的 Python 解析（与 `cleanup.ps1` 同序，跳过 WindowsApps） |
| `AGENTS.md` | 维护/agent 导航：文档入口、检查命令、测试副作用 |
| `CODING_STANDARDS.md` | Review 阶段的判断题标准 |
| `tests\make-test-db.py` | 生成合成 Cookie 数据库 |
| `tests\verify-db.py` | 校验数据库行数与完整性 |
| `backups\` | 自动备份目录（默认 ACL 收紧） |
| `logs\cleanup.log` | 运行日志（UTF-8 BOM，超过 5 MB 轮转） |
| `state\watcher.pid` | 运行中监视器的 PID 和启动时间 |
| `state\watcher.stop` | `-Stop` 临时写入的协作式停止请求 |
| `state\scheduled-task.vbs` | 计划任务的隐藏启动器（`wscript` 0 窗口，等待并传回退出码）；不要手动删除，`-Status` 会检查 |

如果脚本目录不可写，日志会退回到
`%LOCALAPPDATA%\dsh-cookie-cleanup\cleanup.log`。

---

## 4. 快速开始

### 4.1 先看报告（推荐第一次这样跑）

1. 完全退出 DSH（托盘图标 → 退出）。
2. 双击 `dsh-cookie-report.cmd`。
3. 查看 `dsh-auth-*` 数量、有效期数量、请求头估算。

报告只读：默认不创建 `logs\` 或 `backups\`，也不轮转备份。需要留日志时加
`-LogPath`。报告也会尝试获取清理锁；如果恢复/清理正在运行，会提示稍后再试
（退出码 3）。

命令行等价：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 -DryRun
```

### 4.2 手动清理

完全退出 DSH 后双击 `dsh-cookie-cleanup.cmd`，或：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1
```

应用还在运行时会拒绝执行（退出码 2）。可以等待：

```powershell
.\cleanup.ps1 -IfRunning Wait -WaitSeconds 600
```

### 4.3 每次启动前清理（最稳）

不要直接启动原来的 `DeepSeek Harness.exe`，改双击：

```text
start-dsh-clean.cmd
```

先清理，再启动。清理失败/被占用/预演时默认不启动应用；确认要启动时加
`-ForceStart`。

### 4.4 登录后自动清理（推荐日常使用）

双击 `install-autoclean.cmd`。它安装监视器并立即启动当前这次；之后完全退出
DSH，4 秒后自动清理。

它等价于：

```powershell
.\install-task.ps1 -Mode Watch -RunNow
```

查看状态：

```powershell
.\install-task.ps1 -Status
```

停止自动清理（禁用任务/删除启动项，保留备份和日志）：

```powershell
.\install-task.ps1 -Stop
```

彻底卸载（停止 + 删除任务/启动项）：

```powershell
.\install-task.ps1 -Uninstall
```

### 4.5 换电脑：重装 DSH 后部署本工具

在新电脑上按下面顺序做。**双击 `install-autoclean.cmd` 是最后一步的启动入口，不是整个迁移过程。**

1. **安装 DSH 并至少运行一次**
   - 用官方安装包安装 DeepSeek Harness。
   - 启动一次，确认能进入主界面，然后从托盘**完全退出**。
   - 这一步会创建默认数据库
     `%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies`；没有它，报告和清理没有目标。

2. **复制工具目录**
   - 把整个工具目录复制到新电脑，至少包含 `cleanup.ps1`、`cleanup_db.py`、
     `install-task.ps1` 和各个 `.cmd`。
   - **不要复制旧电脑的** `state\`、`logs\`、`backups\`；`state\` 里的启动器
     含旧机器的绝对路径，`backups\` 含敏感 Cookie 数据。
   - 安装后不要移动工具目录：计划任务保存的是绝对路径。

3. **确认依赖**
   - Windows PowerShell 5.1 或 7；
   - Python 3（含 `sqlite3`）。工具会优先使用 DSH 自带的
     `~\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe`；
   - Windows Script Host 可用（隐藏启动器需要；被禁用时 Watch/Daily 会回退到
     直接 PowerShell，Startup 不可用）；
   - 普通用户即可，不需要管理员。

4. **先验证 Python 和数据库路径**
   - 保持 DSH 完全退出。
   - 双击 `dsh-cookie-report.cmd`，确认能读库并显示数量。
   - 失败时按 9.4 C 检查 Python；也可运行
     `powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 -CheckPython`。
   - 使用便携版或自定义 profile 时，在后续命令加
     `-UserDataDir <DSH 用户数据目录>` 或 `-DbPath <Cookies 文件>`。

5. **安装并启动自动清理**
   - 双击 `install-autoclean.cmd`。它等价于：

     ```powershell
     .\install-task.ps1 -Mode Watch -RunNow
     ```

   - 它会注册当前用户的登录计划任务，并立即启动 watcher；不需要管理员。
   - 需要额外参数时直接加在后面，例如：

     ```text
     install-autoclean.cmd -UserDataDir "D:\DSH-Data"
     ```

6. **确认安装状态**
   - 运行：

     ```powershell
     .\install-task.ps1 -Status
     ```

   - 应看到任务 `Running`、`[launcher-ok]`、`[wsh-ok]` 和 watcher PID。
   - 若任务注册失败、WSH 被禁用或被 EDR 拦截，按 9.4 J 处理；不要绕过安全策略。

7. **跑一次端到端验证**
   - 正常启动 DSH，使用后从托盘完全退出。
   - 等约 5 秒，查看 `logs\cleanup.log`，应出现“检测到运行”→“已删除/没有需要清理”
     →“数据库完整性检查: ok”。
   - 也可以再运行 `dsh-cookie-report.cmd`，确认 `dsh-auth-*` 已归零或只剩本次启动的少量。

8. **以后重启**
   - 计划任务在**当前用户登录 Windows 后**自动启动 watcher；登录界面阶段不会启动。
   - 重启后可用 `-Status` 确认任务和 watcher 是否正常。

如果之后再移动工具目录，先在旧路径执行 `-Uninstall`，再在新路径重新运行
`install-autoclean.cmd`；只移动文件会让计划任务指向旧路径。

---

## 5. 命令参考

### 5.1 `cleanup.ps1` 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-DbPath <path>` | 自动探测 | 直接指定 Cookies 数据库；与 `-UserDataDir` 二选一 |
| `-UserDataDir <path>` | `%APPDATA%\@deepseek-ai\dsh-desktop` | 指定 DSH 用户数据目录 |
| `-AllProfiles` | 关 | 同时清理 `Partitions\*\Network\Cookies` |
| `-DryRun` / `-ReportOnly` | 关 | 只报告，不改数据库、不创建备份 |
| `-KeepLatest <n>` | `0` | 保留最近使用的 N 个匹配 Cookie；0 = 全删 |
| `-IfRunning Fail\|Skip\|Wait` | `Fail` | 应用运行时的行为 |
| `-WaitSeconds <n>` | `300` | `Wait` 的等待秒数；0 = 一直等 |
| `-BackupRoot <path>` | `<脚本目录>\backups` | 备份根目录 |
| `-KeepBackups <n>` | `30` | 普通备份保留数量；0 = 保留全部；负数拒绝 |
| `-KeepPreRestore <n>` | `5` | pre-restore 快照保留数量；0 = 保留全部；负数拒绝 |
| `-LogPath <path>` | `<脚本目录>\logs\cleanup.log` | 日志路径 |
| `-Quiet` | 关 | 不输出到控制台（仍写日志） |
| `-SkipProcessCheck` | 关 | 跳过进程检查；仅用于测试/拷贝库 |
| `-StartApp` | 关 | 清理成功后启动 DSH |
| `-ForceStart` | 关 | 清理失败/跳过/预演时也启动 |
| `-CheckPython` | 关 | 执行一次 Python 预检（会多一次冷启动） |
| `-KillApp` | 关 | 强制结束 `DeepSeek Harness` 进程后再清理；会中断任务 |
| `-AppExe <path>` | 自动 | 指定 DSH 可执行文件；显式路径无效会报错 |
| `-AppProcessName <name>` | `DeepSeek Harness` | 进程名；按字面匹配，不做通配符展开 |
| `-Restore <folder>` | — | 从备份文件夹恢复；必须同时给 `-DbPath` |
| `-Watch` | 关 | 后台监视模式 |
| `-WatchMinutes <n>` | `0` | 监视时长；0 = 永久 |
| `-PollSeconds <n>` | `5` | 进程轮询间隔；必须 >= 1 |
| `-HeartbeatMinutes <n>` | `10` | 应用未运行时的心跳检查间隔；0 = 关闭 |
| `-HeartbeatThreshold <n>` | `5` | 心跳清理阈值（累计 `dsh-auth-*` 超过它才清理） |

重要约束：

- `-Restore` 不能与 `-DryRun` / `-ReportOnly` / `-Watch` 同用（退出码 2）。
- `-Restore` 的 `-DbPath` 必须是 `Cookies` 文件本身；传目录会被拒绝。
- `-Restore` 的备份文件夹必须包含一个 `Cookies` 文件。
- `-Watch -DryRun` 不会删除数据库，也不会轮转备份。
- `-AppProcessName` 含引号或换行会在 `install-task.ps1` 中被拒绝；含通配符
  字符时会被当作字面名称，不会匹配多个进程。

### 5.2 `cleanup.ps1` 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功（或监视正常结束） |
| `1` | 发生错误（Python 失败、路径错误、启动应用失败等） |
| `2` | 应用在运行 / 数据库被锁定 / 找不到数据库 / 本次跳过；或非法的恢复参数组合 |
| `3` | 另一个清理或恢复正在进行（互斥量被占用） |

`-Restore` 路径单独返回：`0` 成功，`1` 失败，`2` 应用在运行，
`3` 另一个清理/恢复正在进行。

### 5.3 `cleanup_db.py` 参数

| 参数 | 说明 |
| --- | --- |
| `--db <path>` | 必填，Chromium `Cookies` 数据库 |
| `--dry-run` / `--report-only` | 只报告，不改库 |
| `--keep-latest <n>` | 保留最近使用的 N 个匹配 Cookie |
| `--backup-dir <dir>` | 删除前生成一致性备份到 `<dir>\Cookies` |
| `--no-backup` | 显式允许无备份删除（不推荐） |
| `--vacuum` | 删除后 `VACUUM` |
| `--verify` | 只做 `quick_check` 和计数，用于恢复校验 |
| `--json` | 兼容参数；输出始终是一个 JSON 对象 |

删除规则：

- 只处理 `host_key = '127.0.0.1'` 且 `name` 以大小写敏感的 `dsh-auth-` 开头的行。
- 非预演删除必须提供 `--backup-dir`，否则拒绝；`--no-backup` 可显式覆盖。
- 如果 `--backup-dir` 解析出的 `Cookies` 就是现库本身，拒绝执行。
- 退出码：`0` 成功；`1` 失败；`3` 数据库不存在；`4` 数据库被锁定/占用。

正常输出的 JSON 字段（节选）：

```json
{
  "ok": true,
  "db": "...\\Cookies",
  "total": 80,
  "auth": 75,
  "active": 70,
  "keep": 0,
  "deleted": 75,
  "planned": 75,
  "remaining": 0,
  "total_after": 5,
  "header_bytes": 16875,
  "header_overhead": 1024,
  "header_total": 17899,
  "header_limit": 16384,
  "expired": 5,
  "oldest_expires": "...",
  "newest_expires": "...",
  "backup": "...\\backups\\Cookies-...\\Cookies",
  "quick_check": "ok",
  "dry_run": false,
  "report_only": false
}
```

`--verify` 输出：

```json
{"ok": true, "db": "...", "total": 80, "auth": 75, "quick_check": "ok"}
```

### 5.4 `install-task.ps1` 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Mode Watch\|Daily\|Startup` | `Watch` | 自动清理模式 |
| `-Time HH:mm` | `04:00` | Daily 模式的执行时间 |
| `-TaskName <name>` | `DSH Cookie Cleanup` | 计划任务名称 |
| `-CleanupScript <path>` | `<脚本目录>\cleanup.ps1` | watcher 使用的清理脚本 |
| `-StartupDir <path>` | 当前用户 Startup 目录 | 登录启动项目录（测试/自定义用） |
| `-AppProcessName <name>` | `DeepSeek Harness` | 传给 watcher 的进程名 |
| `-AllProfiles` | 关 | 传给 watcher，清理所有分区库 |
| `-PollSeconds <n>` | `5` | watcher 轮询间隔 |
| `-KeepBackups <n>` | `30` | 传给 watcher |
| `-KeepPreRestore <n>` | `5` | 传给 watcher |
| `-HeartbeatMinutes <n>` | `10` | 传给 watcher；0 关闭 |
| `-HeartbeatThreshold <n>` | `5` | 传给 watcher |
| `-RunNow` | 关 | 安装后立即启动 |
| `-Status` | 关 | 查看任务/启动项/监视器 PID、启动器状态和 WSH 可用性 |
| `-Stop` | 关 | 先禁用计划任务、删除登录启动项；再协作式停止属于当前脚本的 watcher（最多 30 秒）；保留备份/日志 |
| `-Uninstall` | 关 | 停止 watcher；删除登录启动项；注销计划任务 |

模式说明：

- **Watch**：登录时启动隐藏 watcher；等待 DSH 退出 → 4 秒后清理 → 继续等待。
  任务注册失败时自动退回 Startup 隐藏 VBS。WSH 不可用时注册直接 PowerShell
  动作（可能有控制台窗口），但任务注册失败后无法再退回 Startup。
- **Daily**：每天 `-Time` 执行一次；应用在运行时跳过。依赖 Task Scheduler，
  注册失败会退出 1；WSH 不可用时同样使用直接 PowerShell 动作。
- **Startup**：强制写入 Startup VBS，不碰 Task Scheduler；需要 WSH，不可用时
  明确失败并退出 1。

`-Stop` 与 `-Uninstall` 的区别：

- `-Stop`：停 watcher，禁用任务，删除 Startup VBS；任务仍保留（Disabled），
  备份/日志保留。重新启用运行 `install-autoclean.cmd`。
- `-Uninstall`：停 watcher，删除 Startup VBS，注销任务。

### 5.5 `.cmd` 包装器

| 文件 | 等价命令 | 说明 |
| --- | --- | --- |
| `dsh-cookie-cleanup.cmd` | `cleanup.ps1 %*` | 手动清理；结束前 `pause` |
| `dsh-cookie-report.cmd` | `cleanup.ps1 -DryRun %*` | 只读报告；结束前 `pause` |
| `start-dsh-clean.cmd` | `cleanup.ps1 -IfRunning Skip -StartApp %*` | 先清理再启动；退出码 2/3 保留 |
| `install-autoclean.cmd` | `install-task.ps1 -Mode Watch -RunNow %*` | 安装并立即启动 |
| `remove-autoclean.cmd` | `install-task.ps1 -Uninstall` | 彻底卸载 |

包装器使用绝对路径查找 PowerShell：优先
`%ProgramW6432%\PowerShell\7\pwsh.exe`，其次
`%ProgramFiles%\PowerShell\7\pwsh.exe`，最后系统自带的
`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`。

`%*` 原样转发；含 `&`、`|`、`<`、`>`、`^` 的参数必须加引号。复杂参数建议
直接用 `powershell -File ...` 调用。

---

## 6. 备份与恢复

### 6.1 备份位置和命名

普通备份：

```text
backups\Cookies-<yyyyMMdd-HHmmss-fff>-<父目录名>-<8位路径哈希>\Cookies
```

恢复前快照：

```text
backups\pre-restore-<yyyyMMdd-HHmmss-fff>\Cookies
backups\pre-restore-<yyyyMMdd-HHmmss-fff>\Cookies-wal / Cookies-shm / Cookies-journal（如存在）
```

时间戳带毫秒；短哈希来自数据库完整路径，避免多个同名 `Network` 库互相覆盖。

### 6.2 保留和 ACL

- `-KeepBackups` 默认 30，`-KeepPreRestore` 默认 5，分开计数。
- `0` 表示保留全部；负数会被拒绝。
- 轮转只处理本工具命名格式的目录；不会误删 `-BackupRoot` 下其他
  `Cookies-*` 文件夹。
- 默认 `backups\` 会移除继承 ACL，并为当前用户、SYSTEM、Administrators
  授予完全控制；不会主动删除目录上已有的显式 ACE。用 `-BackupRoot` 指向
  共享/备份卷时不改那里的 ACL。
- ACL 收紧后，当前用户/SYSTEM/Administrators 对备份 **文件** 仍有有效的
  FullControl，恢复才能读取。若 `cleanup_db.py --db <备份>\Cookies --json --verify`
  报无法打开，重启 watcher（或运行一次非只读清理）会重新应用文件 ACL；仍失败
  按 9.4 P 处理。

备份包含完整 Chromium Cookie 数据库（包括其他站点的 Cookie 行），属于敏感
数据；不要随意上传或共享 `backups\`，排查问题时也不要直接贴数据库文件。

### 6.3 恢复步骤

1. 完全退出 DSH。
2. 找到要恢复的备份文件夹（包含 `Cookies`）。
3. 执行：

```powershell
.\cleanup.ps1 -Restore ".\backups\Cookies-20261112-112302-123-work-a1b2c3d4" `
             -DbPath "$env:APPDATA\@deepseek-ai\dsh-desktop\Network\Cookies"
```

恢复流程：

1. 校验备份的 `quick_check` 和 `cookies` 表。
2. 把备份复制到目标目录旁的 `Cookies.restore-*`，再次校验。
3. 把现库和 `Cookies-journal` / `Cookies-wal` / `Cookies-shm` 复制到
   `pre-restore-*`。
4. 移走现库的 sidecar，使用 `File.Replace` 原子替换主库。
5. 校验新库；失败则回滚并用 `pre-restore-*` 恢复原状态。
6. 报告成功，并保留 `pre-restore-*` 快照（按 `-KeepPreRestore` 轮转）。

恢复失败时：

- `恢复目标必须是 Cookies 文件，而不是目录`：`-DbPath` 少写了 `\Cookies`。
- `备份文件夹里没有 Cookies 文件`：`-Restore` 指错了文件夹。
- `备份校验失败`：备份损坏/截断，换一个更早的备份。
- `临时文件校验失败`：目标目录无法写入或磁盘问题；现库未改动。
- `恢复后校验失败，已回滚`：新库未通过 `quick_check`，原库已恢复；
  检查 `pre-restore-*` 后换备份重试。
- `回滚未完全成功`：按日志给出的 `pre-restore-*` 路径手工恢复；确保应用已退出。
- `当前文件系统不支持原子替换`：目标卷不支持 `File.Replace`；换到本地 NTFS
  或使用其他恢复方式。

---

## 7. 日志与状态

### 7.1 日志

默认路径：`logs\cleanup.log`。脚本目录不可写时退回
`%LOCALAPPDATA%\dsh-cookie-cleanup\cleanup.log`。

格式：

```text
[2026-11-12 16:21:57] [OK] 已恢复 ... -> ...（total=4, auth=3, quick_check=ok）
[2026-11-12 16:21:57] [INFO] 恢复前状态已备份到 ...
```

级别：`INFO`、`WARN`、`ERROR`、`OK`。

- 文件超过 5 MB 时轮转为 `cleanup-yyyyMMdd-HHmmss.log`，保留最近 5 个。
- 只轮转本工具生成的时间戳文件，不删同目录其他 `cleanup-*.log`。
- 只读报告（`-DryRun` 且未给 `-LogPath`）不会创建日志。

### 7.2 状态文件

| 文件 | 内容 | 清理时机 |
| --- | --- | --- |
| `state\watcher.pid` | 第一行 PID，第二行启动时间（FileTimeUtc） | watcher 正常退出/停止/卸载时删除；`-Status` 会清理失效文件 |
| `state\watcher.stop` | 每行 `PID:StartTime` 的停止请求 | `-Stop` 等待 watcher 退出后删除 |
| `state\scheduled-task.vbs` | 计划任务的隐藏启动器 | `-Uninstall` 或重新安装计划任务时替换/删除 |

`-Status` 优先读 PID 文件；CIM 查询作为旧版本/手动实例的兜底。启动时间校验
用于避免 PID 复用误判。

> **不要删除 `state\`**。计划任务的启动器是 `state\scheduled-task.vbs`；删除或
> 改名后，任务下次启动会失败（`wscript` 找不到脚本）。`-Status` 会显示启动器
> 存在/缺失/内容异常；需要清理时用 `-Uninstall`。`watcher.pid` 和
> `watcher.stop` 也是运行时状态，不要手工搬走。

---

## 8. 自动清理模式

### 8.1 Watch 生命周期

1. 登录时计划任务通过 `wscript.exe` + VBS 以隐藏方式启动 watcher；Startup 模式同样使用 VBS。PowerShell 子进程从创建起就是 0 窗口，不会显示或最小化。安装时会检测 WSH；不可用时 Watch/Daily 改用直接 PowerShell 动作（可能出现控制台窗口），Startup 模式明确失败。
2. watcher 获取 `Local\DshCookieCleanup.Watch`；已有实例则退出。
3. 写 `state\watcher.pid`。
4. 每 `PollSeconds`（默认 5 秒）检查 `DeepSeek Harness` 进程。
5. 检测到运行 → 等待完全退出。
6. 退出后等 4 秒，让 Electron 子进程和 SQLite 释放文件锁。
7. 对每个库执行清理；如果库/锁仍被占用，最多重试 3 次，每次间隔 5 秒。
8. 轮转备份，回到步骤 4。

所有清理/恢复/报告共享 `Local\DshCookieCleanup.Restore`；两个数据操作不会
同时改库。心跳读取也使用这把锁。

### 8.2 心跳兜底

应用未运行时，每 `HeartbeatMinutes`（默认 10 分钟）检查一次；如果累计
`dsh-auth-*` 超过 `HeartbeatThreshold`（默认 5），主动清理。

覆盖三种纯事件驱动会漏掉的情况：

- DSH 更新后进程名变了；
- 改用 `dsh web` 模式（没有这个进程）；
- 应用启动后几秒内就退出（431 崩溃循环形态）。

某个库读不到时，心跳写 WARN、跳过它并继续统计其他库。

### 8.3 Daily 与 Startup

- **Daily**：Task Scheduler 每天执行一次；应用在运行时跳过。常驻不关机的机器
  请用 Watch。
- **Startup**：在 Startup 文件夹写隐藏 VBS；下次登录启动 watcher。需要
  Windows Script Host；WSH 被组策略禁用时会明确失败，不会留下一个无法运行的
  启动项。公司/受管电脑可能被 EDR 拦截，优先用计划任务或手动
  `start-dsh-clean.cmd`。

### 8.4 停止

```powershell
.\install-task.ps1 -Stop
```

流程：禁用计划任务 → 删除 Startup VBS → 写 `state\watcher.stop` → 最多等 30 秒
让 watcher 自己退出 → 超时仍存活的进程强制结束 → 删除停止文件。

如果安装时用了自定义 `-TaskName` / `-StartupDir`，停止/卸载时也需要传入相同值。

---

## 9. 排障手册

### 9.1 先收集这组信息

```powershell
Set-Location '<工具目录>'

# 1. 自动清理状态
.\install-task.ps1 -Status

# 2. 最近日志
Get-Content .\logs\cleanup.log -Tail 100

# 3. 应用是否真的退出
Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue

# 4. 环境
$PSVersionTable.PSVersion.ToString()
python --version

# 5. 数据库是否可读、行数/完整性（应用退出后执行；运行时会被锁定）
python .\cleanup_db.py --db "$env:APPDATA\@deepseek-ai\dsh-desktop\Network\Cookies" --json --verify

# 6. 计划任务/启动项
Get-ScheduledTask -TaskName 'DSH Cookie Cleanup' -ErrorAction SilentlyContinue | Format-List TaskName,State
Get-ChildItem ([Environment]::GetFolderPath('Startup')) -Filter 'DSH Cookie Cleanup.vbs'

# 7. 备份 ACL（如关心隐私）
Get-Acl .\backups | Format-List
```

记录：执行的具体命令、退出码、日志最后 100 行、PowerShell/Python 版本、
是否安装过 watcher、是否改过 `-TaskName` / `-BackupRoot` / `-AppExe`。

**不要**上传 `Cookies` 数据库或 `backups\` 内容；其中包含会话 Cookie。

### 9.2 按退出码定位

| 退出码 | 先看 |
| --- | --- |
| 0 | 正常；如果效果不对，看 9.4 的“数量/删除结果” |
| 1 | 日志中的 `ERROR` 行；Python 路径/权限/参数错误 |
| 2 | 应用是否完全退出、数据库是否被锁定、恢复参数组合 |
| 3 | 是否有另一个清理/恢复进程；等待或结束它 |

### 9.3 按日志关键词定位

| 日志关键词 | 含义 | 处理 |
| --- | --- | --- |
| `找不到可用的 Python 3` | 未找到可用 Python | 安装 Python 3，或设置 `DSH_COOKIE_CLEANUP_PYTHON` 为绝对路径 |
| `Python 预检失败` | `-CheckPython` 失败 | 看日志中的实际 Python 路径和 stderr |
| `数据库被占用` | 应用未完全退出或残留进程 | 托盘退出、任务管理器结束残留；或用 `-IfRunning Wait` / `-KillApp` |
| `disk I/O error` | 真实的磁盘/数据库 I/O 错误（不再归类为“应用占用”） | 检查磁盘、权限、数据库完整性；必要时用备份恢复 |
| `命令行不属于当前脚本` / `[skip-foreign-watcher]` | `-Stop` 发现另一个 checkout 的 watcher | 正常保护；用对应安装目录的 `-Stop` 停止它 |
| `另一个清理/恢复正在进行` | 没拿到 Restore 互斥量 | 等当前操作结束；检查是否有卡住的 `cleanup.ps1`/Python |
| `跳过 ... 另一个清理/恢复` | 同上 | 同上 |
| `备份校验失败` | 备份损坏/截断/不是 cookie 库 | 换一个更早的备份 |
| `临时文件校验失败` | 目标目录写入或 staging 校验失败 | 检查磁盘空间/权限/杀软；现库未改动 |
| `恢复后校验失败` | 新库 `quick_check` 未通过 | 已自动回滚；检查 `pre-restore-*`，换备份重试 |
| `回滚未完全成功` | 回滚某一步失败 | 按日志中的 `pre-restore-*` 手工恢复；确保应用退出 |
| `当前文件系统不支持原子替换` | 目标卷不支持 `File.Replace` | 恢复到本地 NTFS 卷 |
| `恢复目标必须是 Cookies 文件` | `-DbPath` 指向了目录 | 改为 `...\Network\Cookies` |
| `无法收紧备份目录 ACL` | 非 NTFS/网络卷不支持 | 不影响清理；共享备份用 `-BackupRoot` 管理权限 |
| `无法修复部分备份文件 ACL` | 文件 owner/ACL 异常，无法补有效 FullControl | 检查备份文件 owner；重启 watcher 重试；备份可能暂时不可读 |
| `找不到 DeepSeek Harness.exe` | `-StartApp` 找不到可执行文件 | 用 `-AppExe` 指定，或设置 `DSH_DESKTOP_EXE` |
| `-AppExe 指定的文件不存在` | 显式路径错误 | 修正路径；不要依赖静默回退 |
| `已有另一个监视器在运行` | Watch 互斥量被占用 | 正常防重复；`-Status` 查看，必要时 `-Stop` |
| `注册计划任务失败` | 权限/策略/EDR | 见 9.4 的“计划任务”；Watch 会尝试 Startup 回退（WSH 不可用时回退也会失败） |
| `禁用计划任务失败` | 权限/模块不可用 | 用 `-Uninstall` 或手工在任务计划程序禁用 |
| `无法写入监视器 PID 文件` | 目录只读/权限 | `-Status` 可能看不到 PID；检查脚本目录权限 |
| `清理/恢复锁仍被占用` | 清理重试 3 次仍忙 | 下次应用退出再试；检查是否有卡住的恢复 |
| `收到停止请求` | 协作式停止生效 | 正常，无需处理 |
| `心跳检查：无法读取` | 某个库读不到 | 按日志中的库路径检查；其他库仍会统计 |

`-Status` 还会输出以下**状态标记**（不是 `cleanup.log` 日志关键词）：

| 状态标记 | 含义 | 处理 |
| --- | --- | --- |
| `[launcher-ok]` | 任务指向的 VBS 存在且内容可用 | 正常 |
| `[launcher-missing]` | 任务指向的 VBS 缺失 | 重新运行安装；不要删除 `state\` |
| `[launcher-invalid]` | VBS 内容异常 | 重新运行安装 |
| `[launcher-direct]` | 任务直接启动 PowerShell | 正常；WSH 不可用时的回退 |
| `[launcher-orphan]` | 直连任务旁仍有旧 VBS | 当前任务不使用；`-Uninstall` 可清理 |
| `[wsh-ok]` / `[wsh-unavailable]` | WSH 检测结果 | `unavailable` 见 9.4 J |

### 9.4 常见症状与处理

#### A. 清理提示“应用在运行 / 数据库被占用”（exit 2）

- 确认托盘图标已退出，任务管理器中没有 `DeepSeek Harness.exe` 及子进程。
- 等几秒再试；Electron 子进程可能还在释放 SQLite 锁。
- 用 `-IfRunning Wait -WaitSeconds 600` 等待。
- 431 崩溃循环里壳进程可能不断重启 host：用
  `start-dsh-clean.cmd -KillApp`（会中断正在进行的任务）。
- 仍失败时检查是否有其他进程打开了 `Network\Cookies`（杀软、备份软件）。

#### B. “另一个清理/恢复正在进行”（exit 3）

- 等待当前清理/恢复结束；正常只需几秒。
- 检查是否有卡住的 PowerShell/Python：
  `Get-Process powershell,python -ErrorAction SilentlyContinue`。
- 互斥量是 `Local\DshCookieCleanup.Restore`；进程退出后会自动释放，
  AbandonedMutexException 也已被处理。
- 不要通过删除 `state\` 或备份来“解决”锁问题。

#### C. Python 找不到或预检失败

- `.\cleanup.ps1 -CheckPython` 查看实际路径和 stderr。
- 设置 `DSH_COOKIE_CLEANUP_PYTHON` 为绝对路径，例如
  `C:\Python312\python.exe`。
- Microsoft Store 的 `WindowsApps` 转发器会被跳过；安装完整 Python 3。
- 确认 `python -c "import sqlite3;print(1)"` 输出 1。

#### D. 找不到数据库 / 不是 Chromium cookie 数据库

- 确认 DSH 至少启动过一次。
- 默认路径：`%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies`。
- 便携版/自定义 `user-data-dir`：用 `-UserDataDir` 或 `-DbPath`。
- `--verify` 返回 `not a Chromium cookie database` 时，检查 `-DbPath`
  是否指向了别的东西（例如 `Network` 目录或 `TransportSecurity`）。

#### E. 报告显示 0 或读不到

- 默认路径下，应用运行时先命中进程检查：输出「DeepSeek Harness 正在运行
  （PID …）。请先完全退出」并返回 exit 2。
- 如果跳过了进程检查（`-SkipProcessCheck`），或进程检查没有命中但数据库
  仍被锁，Python 侧会输出「数据库被占用（应用可能仍在运行）」，同样是
  exit 2。
- 如果是另一个清理/恢复持锁，输出「另一个清理/恢复正在进行，稍后再试」并
  返回 exit 3；等它结束再试。
- `dsh-auth-*` 为 0 可能只是已经清理过；看 `total` 是否合理。
- 已过期 Cookie 仍会被删除，但不会计入“有效期内”。
- 其他 host 的同名 Cookie 不会计入 `auth`（这是新行为）。

#### F. 431 崩溃循环

1. 任务管理器结束所有 `DeepSeek Harness.exe`。
2. `start-dsh-clean.cmd -KillApp`。
3. 看到删除成功后正常启动。
4. 以后用 `start-dsh-clean.cmd` 或安装 watcher。

#### G. 恢复失败

按 6.3 的错误消息逐条处理。特别注意：

- `-DbPath` 必须是 **Cookies 文件**，不是 `Network` 目录。
- 恢复要求 DSH 完全退出；不要用 `-SkipProcessCheck` 绕过。
- 回滚未完全成功时，原状态在日志给出的 `pre-restore-*` 下；先备份该目录，
  再手工把 `Cookies` 和 sidecar 放回。
- 目标卷不支持 `File.Replace` 时，工具不会冒险做非原子覆盖。

#### H. 自动清理不生效

- `.\install-task.ps1 -Status` 查看任务/启动项/监视器 PID。
- 没安装过 watcher 时，退出应用不会自动清理；用 `start-dsh-clean.cmd`。
- 只安装但没加 `-RunNow` 时，watcher 要到下次登录才启动。
- 计划任务可能被策略/EDR 禁用；看任务计划程序的“上次运行结果”。
- 手动启动一次：`.\install-task.ps1 -Mode Watch -RunNow`。
- 如果刚升级过脚本，旧 watcher 仍在用旧代码；`-Stop` 后重新安装。

#### I. 执行 `-Stop` 后仍自动启动

- `-Stop` 会禁用任务并删除 Startup 项；`-Status` 确认任务状态是 Disabled、
  Startup 项不存在。
- 如果安装时用了自定义 `-TaskName` 或 `-StartupDir`，停止时传入相同参数。
- 需要彻底删除任务用 `-Uninstall`。
- `-Stop` 只停止属于当前脚本的 watcher；另一个 checkout 的 watcher 会打印
  「命令行不属于当前脚本」并跳过，用那个目录的 `-Stop` 停止它。
- 公司策略可能重新启用/重装任务；联系管理员。

#### J. 计划任务注册失败 / EDR 拦截 / WSH 不可用

- 看 `install-task.ps1` 的输出和任务计划程序事件。
- Watch 模式注册失败会自动尝试 Startup VBS；Startup 也可能被 EDR 拦。
- 若 `-Status` 显示 `启动器: 缺失`，重新运行安装；不要只删除
  `state\scheduled-task.vbs`。
- 若 `-Status` 显示 `WSH: 不可用`，说明 Windows Script Host 被计算机或用户
  组策略禁用：Watch/Daily 会回退到直接 PowerShell 动作（可能出现控制台窗口），
  Startup 无法使用。联系管理员启用 WSH，或改用计划任务/手动方案；不要绕过
  安全策略。
- `LastTaskResult`：`267009`（0x41301）表示任务正在运行；`0x80070002` 通常表示
  找不到启动器/脚本。其他值结合任务计划程序事件判断；`-Status` 保留原始值，
  不猜测含义。
- 受管电脑优先用计划任务模式，或只用 `start-dsh-clean.cmd` 手动方案。

#### K. `-Status` 看不到 watcher

- CIM 可能不可用；看 `state\watcher.pid` 是否存在、PID 是否存活。
- 手动启动的 watcher 如果没有写 PID 文件（旧版本/权限问题），只能靠 CIM 或
  `Get-Process` 查命令行。
- `-Status` 的 PID 文件校验会清理失效文件。
- `-Status` 还会显示计划任务启动器和 WSH 状态；这两项与 watcher PID 是独立
  的，启动器缺失不代表当前 watcher 已退出。

#### L. 备份持续增长

- 检查 `-KeepBackups` / `-KeepPreRestore`；0 表示不轮转（保留全部）。
- 轮转只处理本工具命名格式的目录；手工创建的 `Cookies-*` 不会被删。
- 备份根目录可用 `-BackupRoot` 指到容量更大的卷。

#### M. `-StartApp` 没有启动应用

- 清理失败/跳过/预演时默认不启动；看退出码和日志。
- 确认要启动时加 `-ForceStart`。
- 找不到可执行文件时用 `-AppExe` 或 `DSH_DESKTOP_EXE`。
- 应用已在运行时不会重复启动。

#### N. 删除后仍有 `dsh-auth-*`

- 应用在清理后又启动过：新 Cookie 是正常的，用 `start-dsh-clean.cmd` 或 watcher。
- `-KeepLatest N` 会保留最近 N 个。
- 其他 host 的同名 Cookie 会保留（新行为，不是缺陷）。
- 大写 `DSH-AUTH-` 不会被当作目标（大小写精确匹配）。
- 数据库被锁定时会跳过；看日志。

#### O. `.cmd` 参数不生效/报错

- 含 `&`、`|`、`<`、`>`、`^` 的参数要加引号。
- 复杂参数直接用 `powershell -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 ...`。
- 不要在脚本目录放名为 `pwsh.exe` 的文件；包装器现在使用绝对路径，
  但仍不建议从共享目录运行。

#### P. 备份 ACL 警告

- 非 NTFS/网络卷不支持 `icacls` 收紧；备份可能被其他本机用户读取。
- 用 `-BackupRoot` 指到本地 NTFS 目录，或由管理员设置 ACL。
- 默认 `backups\` 应收紧为当前用户/SYSTEM/Administrators。
- 如果备份文件本身存在但 `Get-Acl` 没有有效 ACE，或 SQLite 报
  `unable to open database file`：重启 watcher 会重新应用 ACL；仍失败时检查
  文件 owner，必要时由管理员接管并恢复 FullControl。不要把 ACL 异常误判为
  “数据库被占用”。

---

## 10. 安全边界

- **账号凭据**：不读取、不修改 `~\.dsh\.credentials.yaml`；`dsh-auth-*`
  只是本地 Host 的会话 Cookie。
- **删除范围**：只删 `127.0.0.1` 下大小写精确的 `dsh-auth-` 前缀。
- **备份内容**：完整 Chromium Cookie 数据库，包含其他站点行；属于敏感数据。
  默认 `backups\` ACL 收紧，自定义 `-BackupRoot` 由用户/管理员负责。
- **权限**：计划任务 `RunLevel Limited`，不需要管理员。不要为了方便给脚本
  提权。
- **EDR/受管电脑**：隐藏 VBS + `-ExecutionPolicy Bypass` 可能被判为可疑
  持久化；被拦时用计划任务或手动方案，不要绕过安全策略。
- **`.cmd` 参数**：`%*` 原样转发；含 cmd 元字符的参数必须加引号，不要从
  不受信任的快捷方式传参。
- **恢复**：会覆盖目标 `Cookies` 文件；先确认 `-DbPath` 正确，并保证应用退出。
  不支持 `File.Replace` 的卷上会安全失败。
- **工具目录**：脚本、`cleanup_db.py`、备份都在同一目录；确保该目录只被可信
  用户写入，不要放在共享/同步且可被他人修改的位置。

---

## 11. 卸载

1. 双击 `remove-autoclean.cmd`，或：

```powershell
.\install-task.ps1 -Uninstall
```

2. 确认 `-Status` 显示任务/启动项已不存在、没有监视器进程。
3. 备份和日志不会自动删除；确认不再需要后手工删除 `backups\`、`logs\`、
   `state\`。

如果只想暂时关闭自动清理，用 `-Stop`（保留任务但禁用），之后运行
`install-autoclean.cmd` 可重新启用。

---

## 12. FAQ

**Q：清理会让我退出 DSH 账号吗？**
不会。`dsh-auth-*` 是本地 Host 的每次启动会话 Cookie；账号凭据在
`~\.dsh\.credentials.yaml`，脚本不碰。

**Q：会删除其他网站的 Cookie 吗？**
不会。只删除 `host_key = 127.0.0.1` 且名字以大小写精确的 `dsh-auth-`
开头的行。其他 host 的同名 Cookie 和其他名字的 Cookie 都保留。

**Q：为什么备份比 dsh-auth Cookie 多很多？**
备份是完整 SQLite 一致性快照，包含该 profile 的所有 Cookie 行；这是为了
保证恢复时数据库完整。备份属于敏感数据，默认 ACL 已收紧。

**Q：多久会崩？**
每个 Cookie 30 天过期；30 天内累计超过约 71 个就会触发。按每天启动次数
`r` 估算：`r > 2.37` 会崩；1 次/天稳定在约 30 个，不会崩。详见 README。

**Q：需要管理员权限吗？**
不需要。计划任务以 `RunLevel Limited` 运行。

**Q：`-Stop` 和 `-Uninstall` 有什么区别？**
`-Stop` 停止 watcher、禁用任务、删除登录启动项，但保留任务注册（Disabled）
和备份/日志；`-Uninstall` 会注销任务。

**Q：升级脚本后需要重新安装 watcher 吗？**
计划任务/Startup 项的路径不变，通常不用重装；但**正在运行的 watcher 仍使用
内存中的旧脚本**。要让修复生效，`-Stop` 后重新运行 `install-autoclean.cmd`。

**Q：为什么 `-KeepBackups 0` 不删除备份？**
`0` 的语义是“保留全部”，不是“保留 0 份”。要限制数量请用正数。

**Q：为什么 `-Watch -DryRun` 不删备份？**
预演应该是只读的；现在数据库和备份都不会改动。

**Q：恢复时提示文件系统不支持原子替换怎么办？**
把备份恢复到本地 NTFS 卷，或使用其他恢复方式；工具不会退化成非原子覆盖。

**Q：以后查出新问题，怎么用文档排查？**
按 9.1 收集信息 → 9.2/9.3 按退出码和关键词定位 → 9.4 对应症状处理 →
对照 CHANGELOG 最近行为变化。修复后按第 13 节流程补充文档和测试。

---

## 13. 后续问题记录与文档维护流程

发现新问题时，建议按以下顺序处理，保证下次可复用：

1. **记录现场**
   - 日期、执行的命令、入口（`.cmd`/`ps1`）、退出码。
   - `logs\cleanup.log` 最后 100 行（不要附 Cookie 数据库）。
   - `install-task.ps1 -Status` 输出。
   - PowerShell/Python 版本、是否安装 watcher、是否改过参数。

2. **定位**
   - 用 9.2 的退出码表。
   - 用 9.3 的日志关键词表。
   - 检查 `CHANGELOG.md` 最近一次变更是否改变了相关行为。

3. **复现**
   - 优先使用 `tests\make-test-db.py` 生成合成库。
   - 拷贝真实库到临时目录后用 `-DbPath` 测试；不要在真实 profile 上试恢复。
   - 用 `-DryRun` 验证读取和报告路径。

4. **修复并加回归测试**
   - 在 `tests\run-tests.ps1` 中增加最小复现用例。
   - 运行完整检查（静态 + 套件）：

     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check.ps1 -Full
     ```

   - 只改文档时可用 `-Fast`；提交/完成前用 `-Full`。
   - `-Full` 摘要会同时显示 PASS 和 SKIP 数；watcher 正在运行时，`-Stop` /
     任务相关组会按设计跳过，摘要里会明确标出，不再只显示通过数。

5. **更新文档**
   - 在 `CHANGELOG.md` 增加新的日期小节：问题、影响、修复、涉及文件、测试。
   - 在 `MANUAL.md` 的 9.3/9.4 增加新日志关键词或症状。
   - 如果参数/默认值/退出码变了，更新第 5 节；README 只保留概览和链接。
   - 如果行为变化影响升级，更新“行为变化”表和“升级后自检清单”。
   - 如果新增了判断规则，更新 `CODING_STANDARDS.md`；机械项交给 `tests\check.ps1`。

6. **确认清理**
   - 测试产生的临时目录、临时计划任务、`state\watcher.stop` 等要清理。
   - 不要留下测试用的 `-TaskName` 或 `-StartupDir` 配置。

---

## 14. 诊断命令速查

```powershell
# 状态
.\install-task.ps1 -Status

# 只读报告（推荐先跑）
.\cleanup.ps1 -DryRun
.\cleanup.ps1 -DryRun -LogPath .\logs\diag.log

# 手动清理
.\cleanup.ps1
.\cleanup.ps1 -IfRunning Wait -WaitSeconds 600

# 431 崩溃循环自救
.\cleanup.ps1 -KillApp
# 或
start-dsh-clean.cmd -KillApp

# 校验数据库
python .\cleanup_db.py --db "$env:APPDATA\@deepseek-ai\dsh-desktop\Network\Cookies" --json --verify

# 安装/停止/卸载自动清理
.\install-task.ps1 -Mode Watch -RunNow
.\install-task.ps1 -Stop
.\install-task.ps1 -Uninstall

# 日志
Get-Content .\logs\cleanup.log -Tail 100

# 计划任务/启动项
Get-ScheduledTask -TaskName 'DSH Cookie Cleanup' -ErrorAction SilentlyContinue
Get-ChildItem ([Environment]::GetFolderPath('Startup')) -Filter 'DSH Cookie Cleanup.vbs'

# 备份 ACL
Get-Acl .\backups | Format-List

# 检查（完成前推荐 Full；只改文档可用 Fast）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check.ps1 -Full
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check.ps1 -Fast

# 无可用 Python 时只做静态检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check.ps1 -Fast -SkipPython

# 只跑测试套件（check.ps1 -Full 会调用它）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```
