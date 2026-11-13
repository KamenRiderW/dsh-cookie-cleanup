# BACKLOG / 收敛声明

本文件的作用是**结束迭代**，不是继续列待办。

- 状态：**功能冻结（2026-11-12；当日因备份 ACL 缺陷重开修复后重新冻结）**。
- 验收基线见下；只要基线仍然成立，就不再做实现层改动。
- 新发现的问题先记在这里，满足"重开条件"才动代码。

---

## 1. 验收基线（冻结依据）

| 项 | 基线值 |
| --- | --- |
| `tests\check.ps1 -Fast` | 4/4 静态检查通过，exit 0 |
| `tests\check.ps1 -Full` | 4 项静态 + 套件 **19 组 / 84 断言**，0 失败 0 跳过，约 36 秒，exit 0 |
| 有监视器时跑套件 | 53 通过 / 5 跳过（跳过项均为"已有 watcher → 不调 `-Stop`"的防御性跳过） |
| `install-task.ps1 -Status` | `[launcher-ok]`、`[wsh-ok]`、任务 `Running`、`LastTaskResult=267009`、能列出 watcher PID |
| 窗口 | watcher 父进程为 `wscript.exe`，其 `conhost` 的 `MainWindowHandle=0`（无可见窗口） |
| 端到端 | 日志中完成过一次真实清理：检测退出 → 删除 cookie → 备份 → `quick_check: ok` |

复跑命令：

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\check.ps1 -Full
```

要跑满 84 条断言，先 `install-task.ps1 -Stop`，跑完再 `-Mode Watch -RunNow` 装回去。

## 2. 重开条件（满足任一条才改代码）

1. `check.ps1 -Full` 失败，或基线中任一数字退化。
2. 真实发生一次"该清理却没清理"或"误删/误恢复"。
3. DSH 上游修复了 `--port 0` + authority 命名 Cookie（本工具可退役），或改成不再适用。
4. 安全类问题（越权写、把用户数据当临时文件、凭据泄露）。
5. Windows 大版本升级导致隐藏启动或任务计划行为失效。
6. 安全/备份处理导致已生成备份不可读、不可恢复，或数据完整性受破坏。

不在以上范围内的一律**记录、不修**。文档措辞、输出美观、覆盖率锦上添花都属于此类。

## 2.1 重开记录

| 日期 | 触发 | 处理 | 结果 |
| --- | --- | --- | --- |
| 2026-11-12 | `Protect-BackupRoot` 的 `/T` + `(OI)(CI)` 把备份 `Cookies` 文件 ACL 清空，备份不可读 | 目录保留 `(OI)(CI)F`，已有文件补有效 `F`；增加备份可读性回归断言；重启 watcher 修复现有备份 | 修复并重新冻结；套件 19 组 / 84 断言；6 个真实备份全部可读、`quick_check=ok` |

## 3. 已知残留（明确决定不修）

| 项 | 现状 | 为什么不修 |
| --- | --- | --- |
| `cleanup_db.py` 把 `unable to open database file` 归为“被占用” | 权限/路径错误也会带 `locked=true` | JSON 里 `error` 保留原文，操作者可区分；改成精确区分需要在 Windows 上复现多种 ACL 场景，收益低于风险 |
| `run-tests.ps1:479/759` 用 `(Get-Process -Id $PID).Path` 启动临时 watcher | 从 ISE 跑测试时可能拿到 `powershell_ise.exe` | 只影响测试自身；生产代码已优先 `$PSHOME` → `pwsh` → 回落 |
| `install-task.ps1` 未设 `[Console]::OutputEncoding` | 与 `cleanup.ps1` 输出编码不一致，管道混流时中文可能乱码 | 交互控制台和 `.cmd`（已 `chcp 65001`）正常；断言已改为 ASCII 标记，不依赖编码 |
| `[wsh-unavailable]` 分支在本机不可达 | 需禁用 WSH 才能触发，套件里该分支的断言不会执行 | 已验证 `[launcher-direct]` / `[launcher-orphan]`（用临时直连任务实测），完整回退路径只能靠代码审读 |
| `Get-WatcherProcesses` 的相对路径回退 | watcher 以相对路径启动时，可能匹配到别的 checkout | 安装器一律写绝对路径；`-Stop` 另有精确路径校验 |
| `-Status` 不解释 `LastTaskResult` | 只打印原始值（如 `267009`、`267011`、`0x80070002`） | 刻意不猜含义，常见值含义已写进 MANUAL 9.4 J |
| `Startup` 模式无重试 | 只有计划任务有三次重试 | 回退路径，主路径是计划任务 |
| 无法根治上游 | 仍是用户态缓解 | DSH 修 `--port 0` 后才能退役本工具 |

## 4. 交接给 agent（DSH）的最短路径

1. 装/恢复自动清理：`install-autoclean.cmd`，或
   `powershell -File install-task.ps1 -Mode Watch -RunNow`。
2. 确认：`install-task.ps1 -Status` → `[launcher-ok]` + `[wsh-ok]` + 有 watcher PID。
3. 让用户从托盘退出 DSH（**不要**在 DSH 会话里跑 `cleanup.ps1`，必然 exit 2）。
4. 需要取证时读 `logs\cleanup.log`、`cleanup_db.py --json`、退出码，**不要解析控制台中文**。
5. 卸载：`install-task.ps1 -Uninstall`（会停 watcher、删任务、删启动项、清 `state\`）。

## 5. 维护约定

- 改了行为才写 CHANGELOG；只改文档不算新版本。
- 任何新增断言必须是行为断言或 ASCII 标记（见 `CODING_STANDARDS.md`）。
- 每次改动都必须让 `check.ps1 -Full` 回到基线，否则不开下一个改动。
