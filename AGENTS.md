# AGENTS.md

- 工具与机制：`README.md`
- 使用、参数、退出码、排障：`MANUAL.md`（权威）
- 行为变化历史：`CHANGELOG.md`
- 评审标准：`CODING_STANDARDS.md`
- **已冻结**：验收基线、重开条件、不修的已知残留见 `BACKLOG.md`；不满足重开条件不要改实现
- 检查：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\check.ps1 -Full`；`-Fast` 只做静态检查
- 测试副作用：会临时注册随机计划任务、启动临时 watcher，结束后清理；不要用真实 DSH profile 做恢复测试

## 执行模型（重要）

- 在 DSH 运行且 agent 位于 DSH 会话内时，直接跑 `cleanup.ps1` 会 exit 2：
  宿主仍持有数据库锁；`-IfRunning Wait` 会等宿主退出而自己先死，
  `-KillApp` 会结束宿主自己。
- 当前会话的正确交接：安装 watcher
  （`install-task.ps1 -Mode Watch -RunNow` 或 `install-autoclean.cmd`），
  由用户退出 DSH；watcher 在退出 4 秒后清理。
- `start-dsh-clean.cmd` 是以后的启动入口（启动前清理），不是清理当前会话的办法。
- `-RunNow` 正常走计划任务；Task Scheduler 不可用时 Watch 会回退到 Startup VBS
  （需要 Windows Script Host；WSH 被禁用时安装失败），仍在 DSH 外运行，但可能
  被 EDR 拦截。
- `-KillApp`、`-Restore`、`-SkipProcessCheck` 都必须由用户显式要求；
  `-SkipProcessCheck` 只用于数据库副本。
- 判断结果看退出码、`logs\cleanup.log` 和 `cleanup_db.py --json`；
  不要解析控制台中文（不同宿主代码页可能乱码）。
