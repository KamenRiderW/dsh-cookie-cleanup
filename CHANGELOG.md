# 变更说明

本文件记录 dsh-cookie-cleanup 的行为变更、缺陷修复和升级注意事项。排查新问题时，先看最近一次变更是否改变了相关行为。

---

## 2026-11-12 — 安全与健壮性修复

### 背景

对目录内全部 PowerShell、Python 和 `.cmd` 脚本做了一次缺陷与安全审查。结论：

- 未发现可被远程利用或跨权限提升的漏洞。
- 主要风险是**误伤数据**、**文档承诺的安全保证实际不成立**，以及**破坏性参数处理**。
- 最高危问题已用临时合成数据库实测复现；修复后用 `tests\check.ps1 -Full` 覆盖。

### 高危修复

#### H1. `-Restore` 把目录当成 Cookies 文件，会搬走并替换整个目录

- **位置**：`cleanup.ps1` → `Invoke-Restore`
- **问题**：`-DbPath` 只做了 `GetFullPath`，没有校验是文件还是目录。传入
  `...\Network`（少写 `\Cookies`）时，整个 `Network` 目录会被移到
  `backups\pre-restore-*\Cookies`，然后用备份文件替换原目录；脚本仍以退出码 0
  报告“恢复成功”。
- **影响**：DSH profile 的 `Network` 目录（Cookies、TransportSecurity 等）被
  搬走，应用配置损坏，需要手工恢复。
- **修复**：
  - 恢复目标必须是文件或不存在；目标是目录时拒绝执行并提示
    `...\Network\Cookies`。
  - 源备份 `<folder>\Cookies` 也必须是 leaf file。
- **验证**：`tests\run-tests.ps1` 的 `restore rejects a directory target`。

#### H2. 恢复回滚可能静默失败，却报告“已回滚”；换库不是原子操作

- **位置**：`cleanup.ps1` → `Invoke-Restore`、`Undo-RestoreSwap`
- **问题**：
  - 旧回滚里 `Remove-Item` / `Move-Item` 都带 `-ErrorAction SilentlyContinue`；
    删除新库失败时，原库不会被搬回，但日志仍写“已回滚”。
  - 换库流程是“先把现库移走，再写入新库”，进程被杀/断电/磁盘满时可能留下
    “现库不存在、备份埋在 pre-restore-*”的状态。
- **修复**：
  - 先把现库和 `Cookies-journal` / `Cookies-wal` / `Cookies-shm` **复制**到
    `pre-restore-*`，现库在替换前始终留在原位。
  - 用 `[System.IO.File]::Replace` 原子替换主库。
  - 回滚逐步检查结果，回滚后重新 `quick_check`；失败时明确打印
    “回滚未完全成功”和 `pre-restore-*` 路径。
  - 残留的 `Cookies.rollback-*` 临时文件会在下次运行清理。
  - 不支持 `File.Replace` 的文件系统上安全失败，并给出明确提示。
- **验证**：`tests\run-tests.ps1` 的 `a failed post-restore check rolls back...`。

### 中危修复

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| M1 | `-AppProcessName` 被直接传给 `Get-Process -Name`，通配符可匹配所有进程，`-KillApp` 会杀掉无关进程 | `Get-AppProcesses` 使用 `WildcardPattern::Escape`；`install-task.ps1` 拒绝含引号/换行的进程名 |
| M2 | `-Stop` 只杀当前 watcher，计划任务仍注册（AtLogOn + 失败重启），下次登录又自动启动 | `-Stop` 先禁用计划任务、删除登录启动项，再停止 watcher；`-Uninstall` 才彻底删除 |
| M3 | `-ForceStart` 时应用已被启动，但 `start-dsh-clean.cmd` 仍提示“应用未启动”，exit 3 还归零 | 包装器改为中性、准确的提示；exit 2/3 保留真实退出码 |
| M4 | 删除只按 `dsh-auth-` 名字匹配，不限制 host；`LIKE` 与 Python `startswith` 大小写语义不一致 | 删除/统计/`--verify` 统一限定 `host_key = '127.0.0.1'`，并使用大小写敏感的 `substr(name,1,9)` |
| M5 | 显式 `-AppExe` 无效时被静默忽略，可能启动另一套安装 | 显式 `-AppExe` 或 `DSH_DESKTOP_EXE` 无效时直接报错，不再回退到其他路径 |
| M6 | `-KeepBackups` / `-KeepPreRestore` 为 0 或负数时永不轮转，备份无限增长 | `cleanup.ps1` 拒绝负数；文档明确 `0 = 保留全部` |
| M7 | 心跳读取不拿 Restore 互斥量，可能与恢复并发读到交换中的库 | `Get-CookieAuthCount` 也获取 `Local\DshCookieCleanup.Restore` |
| M8 | `-Watch -DryRun` / 心跳预演仍会轮转并删除备份 | Watch 与心跳中的 `Remove-OldBackups` 增加只读判断 |
| M9 | `cleanup_db.py` 直接调用且不带 `--backup-dir` 时会无备份删除 | 拒绝删除，除非显式 `--no-backup`；另拒绝“备份路径就是现库” |

### 低危修复与加固

- **恢复目标/备份目录类型校验**：拒绝目录、拒绝非 leaf 的 `Cookies` 源。
- **`verify-db.py`**：使用 `Path.as_uri()` 构造只读 URI，正确处理 `#`、`?`、
  `%XX` 和空格；`quick_check` 非 `ok` 时返回非零。
- **`_is_lock_error`**：改用 SQLite 错误码和精确消息，不再因路径包含
  `locked` 而误判为“应用占用”。
- **备份轮转范围**：只处理本工具命名格式的
  `Cookies-<时间戳>-...` / `pre-restore-<时间戳>` 目录；跳过 reparse point；
  轮转与数据操作共享 Restore 互斥量。
- **日志轮转范围**：只删除本工具生成的 `cleanup-yyyyMMdd-HHmmss.log`，
  不再误删同目录其他 `cleanup-*.log`。
- **`.cmd` 解释器解析**：不再使用当前目录优先的 `where pwsh.exe`；按
  `%ProgramW6432%\PowerShell\7\pwsh.exe` → `%ProgramFiles%\PowerShell\7\pwsh.exe`
  → `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 的顺序使用
  绝对路径。
- **`.cmd` 参数透传**：保留 `%*`，但在包装器和 README 中注明：含
  `&`、`|`、`<`、`>`、`^` 的参数必须加引号，不要从不受信任的快捷方式传参。
- **PID 复用 TOCTOU**：`Get-WatcherProcesses` 记录 `StartTimeUtc`，
  `Stop-WatcherProcesses` 在强杀前重新校验进程名和启动时间。
- **协作式停止**：`cleanup.ps1` 检查 `state\watcher.stop`（`PID:StartTime`
  令牌）；`-Stop` 先发停止请求，最多等 30 秒，再强杀超时残留进程。
- **备份目录 ACL**：默认 `backups\` 移除继承权限，并为当前用户、SYSTEM、
  Administrators 授予完全控制；不主动删除已有显式 ACE。`-BackupRoot` 指向
  共享/备份卷时不改那里的 ACL。
- **`-Stop` / `-Uninstall` 可用性**：即使 `cleanup.ps1` 文件已丢失，也能停止
  监视器、删除启动项和注销任务。
- **`File.Replace` 失败提示**：在不支持原子替换的文件系统上明确提示，不再
  表现为泛化的 I/O 错误。

### 行为变化（升级前请确认）

| 项目 | 旧行为 | 新行为 | 需要做什么 |
| --- | --- | --- | --- |
| 删除范围 | 整个 profile 内所有 `dsh-auth-*` | 仅 `host_key = 127.0.0.1` 且大小写精确匹配 | 其他 host 的同名 Cookie 会保留，这是预期 |
| `-Stop` | 只杀当前 watcher | 停止 watcher + 禁用计划任务 + 删除登录启动项；最多等 30 秒 | 想彻底删除任务用 `-Uninstall`；重新启用运行 `install-autoclean.cmd` |
| `-Uninstall` | 停止 + 删除任务/启动项 | 不变 | 无 |
| `cleanup_db.py` 删除 | 无 `--backup-dir` 也会删除 | 拒绝，需显式 `--no-backup` | 直接调 Python 的脚本需补参数 |
| `-Restore` | 接受目录目标（会破坏目录） | 目录目标直接拒绝 | 使用 `...\Network\Cookies` |
| `-AppExe` | 无效路径被忽略 | 显式路径无效时报错 | 修正路径或删除该参数 |
| `-KeepBackups`/`-KeepPreRestore` | 0 或负数永不轮转 | 负数拒绝；0 = 保留全部 | 需要限制数量时用正数 |
| `start-dsh-clean.cmd` 退出码 | 2/3 被归零 | 保留 2/3 | 依赖退出码的自动化需调整 |
| `.cmd` 解释器 | `where pwsh.exe`（当前目录优先） | 绝对路径；优先 Program Files 下的 PowerShell 7 | 非标准位置安装的 pwsh 会回退到 5.1 |
| 默认 `backups\` ACL | 继承父目录 | 移除继承并授予当前用户/SYSTEM/Administrators；已有显式 ACE 保留 | 共享备份请用 `-BackupRoot` 显式指定 |
| `-Watch -DryRun` | 仍轮转备份 | 不轮转 | 预演现在完全只读（数据库和备份都不动） |

### 兼容性

- 备份目录命名和内容格式未变；旧版本产生的备份仍可 `-Restore`。
- 计划任务/登录启动项的路径和参数格式未变；升级不需要重新安装。但**正在运行的
  watcher 仍使用内存中的旧脚本**，要让修复生效需 `-Stop` 后重新运行
  `install-autoclean.cmd`（或注销/重启）。
- `state\watcher.pid` 两行格式兼容；旧 watcher 没有 stop 文件逻辑，`-Stop`
  会在 30 秒后强制结束它。

### 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\check.ps1 -Full
```

当前套件覆盖以下场景（组数/断言数以 `tests\check.ps1 -Full` 输出为准）：

- 恢复成功 / 拒绝目录目标 / 恢复后校验失败回滚
- 只删除 127.0.0.1 的 `dsh-auth-*`，保留其他 host 与无关 Cookie
- 无备份拒绝、`--no-backup` 覆盖、备份路径等于现库时拒绝
- 负数 `KeepBackups` 拒绝
- `-AppProcessName '*'` 不再匹配所有进程
- `verify-db.py` 处理 `#`、`%20`、空格
- 磁盘 I/O 错误不被归类为数据库锁
- 日志轮转保留 5 份，且不动 `cleanup-misc.log`
- 备份轮转只删本工具时间戳格式，`Cookies-manual-copy` 保留
- 持有 Restore 互斥量时 exit 3
- 默认 `backups\` ACL 限制
- `dsh-cookie-report.cmd` 绝对解释器路径
- `-Stop` 协作式停止真实临时 watcher
- `-Stop` 不结束其他 checkout 的 watcher
- `-Stop` 禁用真实注册的临时计划任务（随机名称，测试结束注销）
- 计划任务使用 `wscript.exe` + VBS 隐藏启动器，VBS 等待并传回退出码
- `-Status` 报告启动器存在/缺失，以及 WSH 可用性
- VBS 启动器包含 `On Error Resume Next` 和错误退出检查
- 注册失败时保留已有 VBS 启动器
- `-Stop` 删除临时 Startup 项

测试只使用临时目录和合成数据库；计划任务测试使用随机名称并在 `finally`
中注销；watcher 测试使用临时脚本副本并确保退出。未触碰真实 DSH profile 或
用户已安装的计划任务/启动项。

### 复核修正（同日）

根据一次独立核查，追加了以下修正：

- **文档**：`-Restore` 补 exit 3；exit 2 补「找不到数据库」；`-Stop` 顺序改为
  「先禁用任务/删启动项，再停 watcher」；轮转表述改为只删除符合时间戳格式的
  目录；9.4 E 修正为默认路径先报进程检查、只有跳过/未命中进程检查时才报
  「数据库被占用」；补齐 `cleanup.ps1` 的 9 个 `.PARAMETER` 帮助（含
  `BackupRoot`）。
- **代码**：`disk i/o error` 不再归类为锁；`-Stop` 只结束属于当前脚本的
  watcher（PID 文件或精确命令行路径）；协作等待从 15 秒提高到 30 秒；计划
  任务优先使用 `$PSHOME` 下的 `powershell.exe`/`pwsh.exe`，避免从 ISE 安装
  时写入 `powershell_ise.exe`。
- **测试**：新增锁分类、日志轮转、备份轮转命名、exit 3、外来 watcher 不被
  结束等用例，组数/断言数以 `tests\check.ps1 -Full` 输出为准。外来 watcher
  的提示增加 ASCII 标记 `[skip-foreign-watcher]`，断言不再依赖控制台代码页，
  跨宿主更稳定。
- **维护**：新增 `tests\check.ps1`（`-Fast` 静态检查、`-Full` 静态 + 套件）、
  `AGENTS.md`、`CODING_STANDARDS.md`；`install-task.ps1` 补齐 3 个
  `.PARAMETER` 帮助。`check.ps1` 的控制台断言扫描扩展到 `-like` /
  `-notmatch` / `-contains` 等操作符，复用与 `cleanup.ps1` 同序的 Python
  解析（`tests\resolve-python.ps1`），并支持 `-SkipPython`。
- **计划任务隐藏启动**：Watch/Daily 的计划任务动作改为
  `wscript.exe` + `state\scheduled-task.vbs`。VBS 用
  `sh.Run(command, 0, True)` 从创建起隐藏 PowerShell 窗口，并
  `WScript.Quit code` 把 watcher 退出码传回 Task Scheduler；保留
  失败重试和 `LastTaskResult`，不再依赖 `-WindowStyle Hidden` 与默认终端
  的交互。`-Uninstall` 会清理该 VBS。
- **清理**：删除 `__pycache__`，新增 `.gitignore`。

### 复核加固（同日）

根据第二轮独立核查，追加以下加固：

- **`-Status` 启动器检查**：计划任务使用 `wscript` 时，检查任务实际指向的
  VBS（存在/缺失/内容异常），并显示 `[launcher-ok]` / `[launcher-missing]` /
  `[launcher-invalid]`。直接 PowerShell 动作显示 `[launcher-direct]`；若旁边
  仍有旧 VBS，再显示 `[launcher-orphan]` 并提示 `-Uninstall` 清理。缺失时
  提示重新安装，避免任务静默失败。
- **WSH 探测与回退**：安装前检查 HKLM/HKCU 下
  `SOFTWARE\Microsoft\Windows Script Host\Settings\Enabled` 和
  `wscript.exe`。WSH 不可用时，Watch/Daily 改为直接 PowerShell 动作并打印
  `[wsh-unavailable]` 警告（可能有控制台窗口）；Startup 模式明确失败并退出 1，
  不再写入无法运行的 VBS。`-Status` 显示 `[wsh-ok]` / `[wsh-unavailable]`。
- **VBS 错误处理**：任务和 Startup 两份 VBS 都加入
  `On Error Resume Next`、`CreateObject`/`Run` 后的 `Err.Number` 检查，并把
  内部错误转为 `WScript.Quit 1`，避免 WSH 模态错误框。
- **注册失败保留启动器**：`Install-ScheduledTask` 失败时不再删除
  `state\scheduled-task.vbs`；已有任务可能仍指向它，删除会把旧任务一起弄坏。
  需要清理时用 `-Uninstall`。
- **测试摘要**：`tests\check.ps1 -Full` 现在统计并显示 `SKIP` 数量，不再把
  “50 条通过 + 20 条跳过”只报成“50 条断言”。
- **测试**：新增 `-Status` 启动器存在/缺失、任务 VBS 错误处理、Startup VBS
  错误处理、注册失败保留启动器、直连残留启动器；WSH 不可用环境下相关组会
  明确 SKIP。
- **文档**：README/MANUAL 写明不要删除 `state\`、WSH 回退行为、状态标记，
  以及 `LastTaskResult` 的常见含义。升级后若要让 VBS 新内容生效，仍需
  `-Stop` 后重新安装 watcher。

### 备份 ACL 修复（重开）

- **原因**：`Protect-BackupRoot` 用
  `icacls <backups> /inheritance:r /grant:r *SID:(OI)(CI)F ... /T` 收紧权限。
  `(OI)(CI)` 是继承标志；对文件本身不会产生有效 ACE，导致文件 DACL 为空。
- **影响**：备份 `Cookies` 文件仍在、大小也正常，但当前用户无法读取，
  SQLite 报 `unable to open database file`，`-Restore` 会在备份校验阶段失败。
  重启后 watcher 启动时再次执行该逻辑，会把此前还能读取的备份也变成不可读。
- **修复**：
  - 目录继续使用 `(OI)(CI)F`，保证新文件继承；
  - 对已有文件逐个补有效的 `F` ACE，保证当前用户/SYSTEM/Administrators
    可读取；
  - 单个文件修复失败写 WARN，不再静默留下不可读备份。
- **验证**：扩展 `Test-BackupAclHardened`，预置一个合法备份，ACL 收紧后断言
  文件仍可读且 `quick_check=ok`。修复前该用例红，修复后套件
  **19 组 / 84 断言**全绿；重启 watcher 后现有 6 个备份全部可读、
  `quick_check=ok`。
- **重开记录**：`BACKLOG.md` 增加“备份不可恢复”重开条件，并记录本次修复后
  重新冻结。

### 文件变更

| 文件 | 变更 |
| --- | --- |
| `cleanup.ps1` | 恢复校验/原子替换/回滚、host 过滤配合、互斥量、协作停止、ACL、轮转、参数校验、AppExe、补齐 9 个帮助参数；备份 ACL 改为目录继承 + 文件有效 `F` |
| `cleanup_db.py` | host 过滤、大小写一致、备份强制、self-backup 拒绝、错误分类（`disk i/o error` 不再视为锁） |
| `install-task.ps1` | `-Stop` 语义、任务禁用、Startup 清理、PID 身份、协作停止、watcher 归属、30 秒等待、`$PSHOME` 宿主、HKLM/HKCU WSH 探测/回退、启动器/残留状态检查 |
| `dsh-cookie-cleanup.cmd` 等 5 个 `.cmd` | 绝对解释器路径、参数引号说明 |
| `tests\check.ps1` | Fast/Full 检查：语法、help 覆盖、控制台断言扫描、测试套件；Full 摘要显示 SKIP 数 |
| `tests\run-tests.ps1` | 自测套件（锁分类、日志/备份轮转、exit 3、watcher 归属、启动器状态、注册失败保留、直连残留、备份文件可读性等；由 `check.ps1` 调用） |
| `tests\resolve-python.ps1` | 测试/检查共用的 Python 解析（与 `cleanup.ps1` 同序） |
| `AGENTS.md` | 维护/agent 导航：文档入口、检查命令、执行模型、测试副作用 |
| `CODING_STANDARDS.md` | Review 阶段的判断题标准 |
| `state\scheduled-task.vbs` | 计划任务的隐藏启动器（`wscript` 0 窗口，等待并传回 watcher 退出码；错误时静默退出 1） |
| `tests\make-test-db.py` | 新增 `--foreign-auth` |
| `tests\verify-db.py` | URI 编码、quick_check 退出码、host 过滤 |
| `.gitignore` | 忽略 `__pycache__`、`*.pyc`、`backups/`、`logs/`、`state/` |
| `README.md` | 同步新行为、退出码、`-Stop` 顺序、轮转表述、WSH/启动器状态 |
| `MANUAL.md` | 使用与排障手册；同步退出码、30 秒、disk I/O、watcher 归属、WSH/启动器状态、备份 ACL |
| `BACKLOG.md` | 验收基线 19 组 / 84 断言、重开条件与本次重开记录 |
| `CHANGELOG.md` | 本文件 |

### 升级后自检清单

1. 如果已安装 watcher：`.\install-task.ps1 -Stop`，然后重新运行
   `install-autoclean.cmd`，确保新脚本生效。
2. `.\install-task.ps1 -Status`：确认任务/启动项/监视器状态符合预期。
3. 运行 `dsh-cookie-report.cmd`：确认能读库、数量与请求头估算正常。
4. 运行一次 `dsh-cookie-cleanup.cmd`：确认退出码 0，日志有备份和
   `数据库完整性检查: ok`。
5. 可选：运行 `tests\check.ps1 -Full` 验证本机环境（静态检查 + 套件）。
6. 如果备份包含敏感数据，检查 `Get-Acl .\backups` 是否已收紧。

### 已知限制

- `.cmd` 的 `%*` 参数透传保留；Batch 无法在保留任意参数语义的同时彻底消除
  cmd 解析风险。含 `&`、`|`、`<`、`>`、`^` 的参数必须加引号，不要从不受信任
  的快捷方式传参。
- 只对默认 `backups\` 收紧 ACL；显式 `-BackupRoot` 由用户/管理员管理。
- 在不支持 `File.Replace` 的文件系统上恢复会安全失败，不会退化为非原子复制。
- 协作式停止最多等 30 秒；超时仍会强制结束，极端情况下 Python 子进程可能
  继续完成当前操作。
- 本工具仍是上游 bug 的用户态缓解；DSH 修复 `--port 0` + authority 命名 Cookie
  的机制后才能根治。
- 隐藏启动依赖 Windows Script Host。WSH 被组策略禁用时，Watch/Daily 会回退到
  直接 PowerShell 动作（可能出现控制台窗口），Startup 模式不可用。
- 不要删除 `state\`；`state\scheduled-task.vbs` 是计划任务的实际启动目标，
  缺失时 `-Status` 会报 `[launcher-missing]`，任务下次启动会失败。
