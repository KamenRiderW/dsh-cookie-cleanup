# DSH Desktop Cookie 清理工具

这个工具用来清理 DSH Desktop 每次启动都会留下、并在 30 天后才过期的
`dsh-auth-*` Cookie。它不是"清理器"视频里那种只能缓解一次的工具：配合
"启动前清理"或"退出后自动清理"，它可以把 Cookie 数量长期压回 1 个左右。

> 视频介绍（Bilibili）：[431 崩溃 一键清](https://www.bilibili.com/video/BV1doWv6WEkq/)

> 文档入口：变更说明见 [CHANGELOG.md](CHANGELOG.md)，完整使用、参数参考与排障
> 流程见 [MANUAL.md](MANUAL.md)。参数、退出码和行为以 MANUAL 为准；维护/评审
> 导航见 [AGENTS.md](AGENTS.md) 和 [CODING_STANDARDS.md](CODING_STANDARDS.md)。

> 结论先说：bug 是真的，触发条件是**启动次数**，不是使用时长。
> 但"每天 1 次 → 71 天崩"这个说法不准确：Cookie 30 天后开始过期，
> 每天 1 次会稳定在约 30 个，永远到不了 71 个。真正的阈值约为
> **2.4 次/天**（30 天内累计超过 71 个）。

---

## 1. 机制（代码依据）

DSH Desktop 的 Electron 主进程启动本地 Host 时，参数是写死的：

```js
// dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js
args: ["--no-open", "--host", "127.0.0.1", "--port", "0"]
```

`--port 0` 表示每次启动都由系统分配一个**新的随机端口**。Host 的
浏览器会话 Cookie 名字由请求的 authority（`host:port`）哈希得到：

```js
// dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js
const COOKIE_PREFIX = "dsh-auth-";
function cookieName(authority) {
  return COOKIE_PREFIX + encodeBase64Url(createHash("sha256").update(authority).digest());
}
```

Cookie 的属性是 `Max-Age=30 天; Path=/; HttpOnly; SameSite=Strict`。
端口每次变，名字就每次变，于是每次启动都会在
`127.0.0.1` 下新增一个 Cookie，而不是覆盖旧的。

Electron 主进程的欢迎页后端用 `net.fetch(..., { credentials: "include" })`
请求这个地址，Cookie 就落进了 Electron 默认会话的持久化 Cookie 数据库：

```js
// lib/main.js
welcomeBackend = await connectDesktopWelcome(
  ready.url,
  (input, init) => net.fetch(input, init),
  async () => (await session.defaultSession.cookies.get({ url: ready.url }))
    .map((cookie) => `${cookie.name}=${cookie.value}`).join("; ")
);
```

代码里没有任何 `cookies.remove` 或启动时清理旧 `dsh-auth-*` 的逻辑。

### 为什么是 71 / 72 个

一个 `dsh-auth-*` 的请求头开销约为：

| 部分 | 字节 |
| --- | --- |
| 名字 `dsh-auth-` + base64url(sha256) | 52 |
| `=` + 值 `v1.<payload>.<hmac>` | 约 169～174（本机实测约 169） |
| `; ` 分隔 | 2 |
| **合计** | **约 223～228** |

Node `http` 服务器的默认请求头上限是 **16384 字节**。除去 `Cookie: ` 前缀和
Host、User-Agent 等其它头（脚本按 1 KiB 估算）：

```text
(16384 - 1024) / 225 ≈ 68.3
16384 / 225 ≈ 72.8
```

所以真实崩溃点通常在 **68～71 个**之间，71 只是量级上的近似值；其它请求头
越大，越早触发。第 72 个左右一定会超过 16 KiB，Node 在进入业务代码之前
就返回 `431 Request Header Fields Too Large`。欢迎页后端拿到非 303 响应，
抛出 `desktop welcome: Web authentication failed`，启动失败——看起来就是
"启动崩溃"。

可用下面的命令自行验证上限：

```powershell
node -e "const http=require('http'); console.log(http.maxHeaderSize)"   # 16384
```

### 数量随时间的变化

每次启动 +1，每个 Cookie 在签发 30 天后过期。设每天启动 `r` 次：

- `r > 71/30 ≈ 2.37`：第 30 天之前就会到 71 个，**会崩**；
  3 次/天约第 24 天，10 次/天约第 7 天。
- `r < 2.37`：30 天后开始过期，稳定在 `30r` 个，**不会崩**；
  1 次/天稳定在约 30 个。

所以"清理一次"能撑多久，取决于你的启动频率：3 次/天大约能撑 24 天，
10 次/天只能撑 7 天。真正长期有效的做法是**每次启动前清理**，或者
**退出后自动清理**——本工具两种都支持。

---

## 2. 这个工具做什么

1. 找到 `%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies`
   （可选加 `-AllProfiles` 清理 `Partitions\*\Network\Cookies`）。
2. 确认 DeepSeek Harness 已经完全退出（Electron 运行时会独占锁定该数据库）。
3. 只删除 `127.0.0.1` 下 `name` 以 `dsh-auth-` 开头的行，其他 Cookie
   （包括其他 host 上的同名 Cookie）一律不动。
4. 删除前用 SQLite 的在线备份 API 生成一致快照，放到 `backups\`。
5. 删除后执行 `PRAGMA quick_check` 校验数据库。
6. 报告清理前后的数量、预计请求头大小、最早/最晚过期时间。

它**不会**：

- 删除账号登录凭据（账号 token 在 `~\.dsh\.credentials.yaml`，与本 Cookie 无关）；
- 删除聊天记录、记忆、知识库、设置；
- 在应用运行时强行改数据库（唯一例外是显式使用 `-KillApp`：先强制结束
  应用，再清理；会中断进行中的任务）；
- 修改 `app.asar` 或应用安装文件。

---

## 3. 使用

### 3.1 先看报告（推荐第一次这样跑）

先完全退出 DeepSeek Harness（托盘图标 → 退出；任务管理器里不应再有
`DeepSeek Harness.exe`），然后双击：

```text
dsh-cookie-report.cmd
```

它会显示当前 `dsh-auth-*` 数量、估算请求头大小、最早/最晚过期时间，
但**不会删除**。报告会区分"总数 / 有效期内 / 已过期"：只有有效期内的
Cookie 会真正出现在请求头里，已过期的不会被发送（但仍会被一并删除）。
报告默认**不创建** `logs\` 或 `backups\`，也不轮转备份，只读位置也能跑；
需要留日志时加 `-LogPath`。报告也会尝试拿同一把清理锁；如果恢复/清理正在
运行，会提示"稍后再试"（exit 3），不会读到文件交换中途的数据库。

命令行等价写法：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\cleanup.ps1" -DryRun
```

退出码和 `-Restore` 返回值的完整含义见 [MANUAL.md](MANUAL.md) 5.2。
日常速记：`0` 成功、`1` 失败、`2` 跳过/锁定/找不到库、`3` 另一个操作进行中。

### 3.2 手动清理

双击：

```text
dsh-cookie-cleanup.cmd
```

或者：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\cleanup.ps1"
```

如果应用还在运行，脚本会拒绝执行并提示先退出。也可以让它等：

```powershell
.\cleanup.ps1 -IfRunning Wait -WaitSeconds 600
```

### 3.3 每次启动前自动清理（最稳）

不要直接双击原来的 `DeepSeek Harness.exe`，改双击：

```text
start-dsh-clean.cmd
```

它会先清理（应用没运行，数据库可写），再启动应用。这样无论你一天启动
多少次，数据库里最多只有当前这次启动产生的一个 Cookie。

如果清理失败、被占用，或者只是 `-DryRun` 预演，`-StartApp` 默认**不会**
拉起应用，避免在 431 状态下再次启动失败；确认仍要启动时加 `-ForceStart`。

可以把这个 `.cmd` 发送到桌面快捷方式，替换原来的启动方式。

### 3.4 登录后自动清理（推荐日常使用）

最简单：双击 `install-autoclean.cmd`。它会安装监视器并**立即启动当前这次**，
之后你完全退出桌面端，就会在 4 秒后自动清理。它等价于下面这条命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\install-task.ps1" -RunNow
```

默认是 `Watch` 模式：

- 优先注册 Windows 计划任务（登录时启动）；
- 如果 Task Scheduler 不可用（权限受限的机器），自动退回到
  `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` 下的隐藏启动项；
- 两种方式都会在后台等待 `DeepSeek Harness` 退出，退出 4 秒后清理，
  然后继续等待下一次启动/退出。

**自动监视器到底是什么**：一个后台 PowerShell 进程，由计划任务的
`wscript.exe` + VBS 启动器以 0 窗口启动；不创建可见或最小化的 PowerShell
窗口，不是注入 DSH，也不改应用文件。它每 5 秒检查一次有没有 `DeepSeek Harness` 进程：

- 没运行 → 继续等；
- 运行中 → 等它完全退出；
- 退出 4 秒后 → 跑一次清理，然后回到等待。

> **WSH 依赖**：隐藏启动器依赖 Windows Script Host。安装时会检测 HKLM/HKCU
> 策略；如果 WSH 被组策略禁用，Watch/Daily 会回退到直接 PowerShell 动作
> （可能出现控制台窗口）并打印警告，Startup 模式则不可用。不要手动删除
> `state\scheduled-task.vbs`，否则计划任务下次启动会失败；`-Status` 会显示
> 启动器状态，直连回退后残留的旧 VBS 会标为 `[launcher-orphan]`。

所以它不依赖"定时"，也不会在你使用应用时碰数据库。代价是登录后会多一个
几乎不占 CPU 的后台进程，可以用下面的 `-Stop` / `-Uninstall` 随时去掉。

**防重复**：监视器启动时拿本地互斥量 `Local\DshCookieCleanup.Watch`。
双击两次 `install-autoclean.cmd`，或"计划任务 + `-RunNow`"同时存在时，
第二个监视器会直接退出并写一条"已有另一个监视器在运行"，不会两个一起删。
所有会改库的清理（手动 / Daily / Watch / 心跳）还共享
`Local\DshCookieCleanup.Restore`，与恢复互斥；恢复进行中清理会跳过。

**心跳兜底**：除了"等进程退出"，应用未运行时每 10 分钟还会检查一次；
如果 `dsh-auth-*` 累计超过 5 个，就主动清理。这样以下三种纯事件驱动会漏掉
的情况也能在 10 分钟内自愈：

- DSH 更新后进程名变了；
- 改用 `dsh web` 模式（根本没有这个进程）；
- 应用启动后几秒内就退出（431 崩溃循环的形态）。

用 `-HeartbeatMinutes 0` 关闭心跳，用 `-HeartbeatThreshold` 改阈值。
某个库读不到时，心跳会在日志里写一条 WARN 并跳过它，继续统计其它库，
不会因为一个坏库就让整个兜底静默停摆。

安装器可以把这些参数透传给监视器，例如：

```powershell
.\install-task.ps1 -AllProfiles -KeepBackups 60 -KeepPreRestore 10 -PollSeconds 3 -HeartbeatMinutes 20
```

双击 `install-autoclean.cmd` 时也可以带参数：
`install-autoclean.cmd -AllProfiles -KeepBackups 60`。

> **公司/受管电脑注意**：Startup 里的 `.vbs` 用隐藏 PowerShell +
> `-ExecutionPolicy Bypass` 启动，可能被 EDR 判为可疑持久化并拦截。
> 如果被拦，改用默认的计划任务模式，或只用 `start-dsh-clean.cmd` 手动方案；
> 不要为绕过安全软件去改策略。想登录时不闪控制台可以用 `-Mode Startup`
> （VBS 隐藏启动），但要先确认公司策略允许。

> **注意：只有安装过监视器后，退出桌面端才会自动清理。**
> 没安装时，退出应用不会发生任何事；需要手动运行或使用
> `start-dsh-clean.cmd`。如果只用 `install-task.ps1` 安装而没加
> `-RunNow`，监视器要到下次登录才启动；双击 `install-autoclean.cmd`
> 则会安装并立即启动当前这次。

查看状态：

```powershell
.\install-task.ps1 -Status
```

`-Status` 会显示计划任务、登录启动项，以及当前监视器进程 PID。PID 来自
监视器自己写的 `state\watcher.pid`，即使 CIM 查询不可用也能看到；CIM 只作为
旧版本/手动实例的兜底。它还会检查计划任务启动器（存在/缺失/内容异常）和
Windows Script Host 是否可用。

停止自动清理：

```powershell
.\install-task.ps1 -Stop
```

`-Stop` 会禁用计划任务、删除登录启动项，并协作停止 watcher。完整的执行顺序、
30 秒等待和与 `-Uninstall` 的区别见 [MANUAL.md](MANUAL.md) 5.4/8.4。
备份和日志保留；重新启用请再运行 `install-autoclean.cmd`。

卸载（同时删除计划任务/启动项，并停止监视器）：

```powershell
.\install-task.ps1 -Uninstall
```

### 3.5 每天定时清理（可选）

```powershell
.\install-task.ps1 -Mode Daily -Time 03:30
```

这个模式依赖 Task Scheduler；如果 03:30 时应用还开着，本轮会自动跳过。
它只适合"晚上会关掉应用"的机器。**常驻不关机的机器请用 3.4 的 Watch 模式。**

### 3.6 恢复备份

> 本节是速览；完整的命名、保留、ACL、恢复和失败处理见
> [MANUAL.md](MANUAL.md) 第 6 节。

脚本每次删除前都会在
`backups\Cookies-<时间>-<目录名>-<短哈希>\Cookies` 留一份完整快照。
短哈希来自数据库完整路径，所以 `-AllProfiles` 同时清多个父目录都叫
`Network` 的库时也不会互相覆盖；时间戳带毫秒，同一秒内连续清理也不会撞名。
普通备份默认保留最近 30 份（`-KeepBackups`），`pre-restore-*` 单独保留最近
5 份（`-KeepPreRestore`），两者分开计数，不会出现"刚恢复完的 pre-restore
把唯一可用备份挤掉"；Watch 模式每轮也会轮转。两个参数设为 `0` 表示不轮转
（保留全部），负数会被拒绝。轮转只处理符合本工具时间戳格式的
`Cookies-yyyyMMdd-HHmmss-fff-...` / `pre-restore-yyyyMMdd-HHmmss-fff`
目录；名称不符合该格式的文件夹（包括其他工具的 `Cookies-*`）不会删除。

恢复失败时脚本会重试删除 `Cookies.restore-*` 临时文件；每次实际清理/恢复
开始也会扫描目标目录，清掉历史残留，并在日志里写 INFO。这样即使删除那一刻
被杀软或文件锁挡住，也不会在 `Network\` 里长期留一份 cookie 副本。
恢复（应用必须先退出）：

```powershell
.\cleanup.ps1 -Restore ".\backups\Cookies-20261112-112302-123-work-a1b2c3d4" `
             -DbPath "$env:APPDATA\@deepseek-ai\dsh-desktop\Network\Cookies"
```

`-Restore` 不能和 `-DryRun` / `-ReportOnly` 同时使用，脚本会直接报错退出，
避免 `dsh-cookie-report.cmd` 这种"报告入口"误执行恢复。`-Restore` 与
`-Watch` 同传也会直接报错，不再静默让恢复胜出。恢复本身还有
`Local\DshCookieCleanup.Restore` 互斥量，两个恢复不会同时跑；普通清理也
共享这把锁，恢复与清理不会同时改库。

`-DbPath` 必须是 `Cookies` 文件本身；如果误传 `Network` 这样的目录，脚本会
拒绝执行且不改动任何文件，并提示正确的子路径。

恢复前脚本会先用 `PRAGMA quick_check` 校验备份；损坏或截断直接拒绝，不碰现库。
真正换库时先把备份复制到同目录的临时文件、再校验一次，确认可读后把现库和
`Cookies-journal` / `Cookies-wal` / `Cookies-shm` 复制到 `pre-restore-<时间>\`，
再用 `File.Replace` 原子替换现库（不是先搬走现库再写入），最后校验新库。
任何一步失败都会尝试回滚；回滚是否成功会写入日志，失败时明确给出
`pre-restore-*` 路径，不会把失败报告成"已回滚"。这样即使换库中途 Electron
抢锁或磁盘写满，也不会出现"原库搬走了、新库没写上"的状态；复制并移走
`-wal`/`-shm` 也避免残留 WAL 让已删的行"复活"。在不支持 `File.Replace`
的文件系统（如某些 FAT 或网络卷）上，恢复会安全失败并给出提示，不会退化成
"先删除再复制"的非原子写入。

也可以单独校验一个库：

```powershell
python .\cleanup_db.py --db ".\backups\Cookies-...\Cookies" --verify --json
```

### 3.7 清理后如何验收

按下面四条做，能确认整条链路真的通了：

1. **清理前**：桌面端完全退出后运行 `dsh-cookie-report.cmd`，记下
   `dsh-auth-* N 个（有效期内 M）`和估算请求头大小。
2. **清理日志**：打开 `logs\cleanup.log`，最后一次成功清理应包含：
   ```
   已删除 N 个；剩余 dsh-auth-* 0 个。
   备份: ...\backups\Cookies-...
   数据库完整性检查: ok
   ```
   不应出现 `失败` 或 `跳过`。如果看到"数据库被占用"，说明应用没退干净。
3. **清理后**：再运行一次 `dsh-cookie-report.cmd`，应显示
   `dsh-auth-* 0 个（有效期内 0，已过期 0）`，请求头估算也回到接近 0。
4. **闭环验证**：正常启动应用、用一会儿、完全退出。如果装了监视器，
   `logs\cleanup.log` 应新增一轮清理（通常"已删除 1 个"），再报告仍是
   0 个。连续做两三次都是 0～1 个，就说明不会再累积到 70 左右。

装了自动监视器后，还可以用 `.\install-task.ps1 -Status` 确认计划任务/
登录启动项存在。

---

## 4. 安全性

- **不会退出账号**：`dsh-auth-*` 只是本地 Host 的浏览器会话 Cookie，
  每次启动都会用启动 token 重新签发。真正的账号凭据在
  `~\.dsh\.credentials.yaml`，脚本不碰。
- **只删 `127.0.0.1` 下的 `dsh-auth-` 前缀**：其他站点（包括其他 host 上的
  同名 Cookie）保持原样。
- **备份目录默认收紧 ACL**：默认的 `backups\` 会在实际清理前移除继承权限，
  并为当前用户、SYSTEM 和 Administrators 授予完全控制；不会主动删除目录上
  已有的显式 ACE。用 `-BackupRoot` 指向共享/备份卷时不会改那里的 ACL，
  由该目录的管理者负责。
- **解释器使用绝对路径**：`.cmd` 包装器优先使用
  `%ProgramW6432%\PowerShell\7\pwsh.exe`，找不到时回退到系统自带的
  Windows PowerShell 5.1；不再使用当前目录优先的 `where pwsh.exe`。
  包装器把额外参数原样传给脚本，含 `&`、`|`、`<`、`>`、`^` 的参数需要
  加引号，不要从不受信任的快捷方式传参。
- **先备份再改**：备份是 SQLite 一致性快照，可直接用 `-Restore` 还原。
- **删除后校验**：`PRAGMA quick_check` 必须返回 `ok`。
- **不改安装文件**：应用更新不会覆盖本工具；本工具也不会被应用更新破坏。
- **失败即停**：数据库被占用、路径找不到、Python 缺 sqlite3 时都会明确报错，
  不会"尽力删一点"。

---

## 5. 限制

1. **应用运行时不能清理**。Electron 以独占方式打开 `Network\Cookies`，
   任何进程都读不了。这是脚本要等你退出、或让监视器等退出的原因。
2. **必须完全退出**。关窗口不等于退出；托盘图标还在时数据库仍被锁定。
3. **这是缓解，不是上游修复**。只要还用 `--port 0` + 按 authority 命名
   Cookie，新 Cookie 就会继续产生；本工具负责及时清掉。
4. **监视器是一个后台 PowerShell 进程**（由 `wscript`/VBS 隐藏启动，无窗口）。介意常驻进程的话，只用
   3.3 的启动前清理即可。
5. **多用户/多开**：脚本按当前用户的 `%APPDATA%` 查找；如果使用便携版
   或自定义 `user-data-dir`，用 `-UserDataDir` / `-DbPath` 指定。
6. **互斥量是 `Local\` 会话级**：同一登录会话内防重复；跨用户或 RDP
   会话不保证只有一个监视器，但每个会话各清各的，SQLite 锁会兜底。
7. **EDR/受管电脑**：隐藏 VBS + PowerShell Bypass 可能被拦，见 3.4 的提醒。
   被拦时用计划任务模式或手动 `start-dsh-clean.cmd`，不要绕过安全策略。
   若 Windows Script Host 被组策略禁用，计划任务会回退到直接 PowerShell
   动作（可能出现窗口），Startup 模式不可用。

---

## 6. 如果已经启动不了（431）

431 崩溃循环里，壳进程可能一直在重启 host，数据库始终被锁，普通
`start-dsh-clean.cmd` 会一直 `[Skip]`。这时用强制自救：

```text
start-dsh-clean.cmd -KillApp
```

它会：

1. 强制结束所有 `DeepSeek Harness` 进程（包括子进程）；
2. 等待进程完全退出、数据库解锁；
3. 清理 `dsh-auth-*`；
4. 清理成功后启动应用。

**注意**：`-KillApp` 会中断正在进行的生成/工具调用，只建议在 431 崩溃循环
或应用卡死时用。正常监视器路径是"退出 4 秒后清理"；`-KillApp` 路径最多要
等 20 秒进程退出 + 2 秒缓冲，再加清理时间，约 22 秒。

不想用命令行，也可以手动：

1. 任务管理器结束所有 `DeepSeek Harness.exe`；
2. 双击 `dsh-cookie-cleanup.cmd`；
3. 看到"已删除 N 个；剩余 0 个"后，再正常启动应用；
4. 以后用 `start-dsh-clean.cmd` 启动，或安装 3.4 的自动监视器。

---

## 7. 上游修复建议（给 DSH 开发团队）

按优先级：

1. **Desktop 壳在启动时清理旧 Cookie**：在 `app.whenReady()` 后、
   `connectDesktopWelcome` 之前，用 `session.defaultSession.cookies`
   删除所有 `dsh-auth-*`（可用 `cookies.get({})` + `cookies.remove(url, name)`）。
   这是最小、最安全的修复。
2. **Cookie 名不再绑定端口**：`cookieName` 只哈希 hostname（如
   `127.0.0.1`），不哈希 `host:port`。这样同一台机器反复启动会覆盖同一个
   Cookie。需要确认同一 host 上多实例并存的场景（当前 `--port 0` 允许多实例，
   但 Desktop 一般单实例）。
3. **Host 启动参数改为固定端口**（如 `--port 7990`），并处理端口占用。
   这样 authority 稳定，Cookie 名也稳定。
4. 临时缓解：Host 启动时加 `--max-http-header-size=65536`，把上限从
   16 KiB 提高；但这只是把崩溃点从约 70 个推到约 287 个，不解决累积。

对本机来说，最彻底的是第 1 条；在官方修复前，本工具就是它的用户态替代。

---

## 8. 文件说明

| 文件 | 用途 |
| --- | --- |
| `README.md` | 机制说明、使用概览、上游修复建议 |
| `MANUAL.md` | 使用手册：参数、备份/恢复、自动清理、排障流程、诊断命令 |
| `CHANGELOG.md` | 变更说明：修复记录、行为变化、升级注意、测试覆盖 |
| `AGENTS.md` | Agent 导航：文档入口、检查命令、测试副作用 |
| `CODING_STANDARDS.md` | Review 阶段的判断题标准 |
| `cleanup.ps1` | 主脚本：检查进程、调用 Python、备份、报告、监视模式、恢复 |
| `cleanup_db.py` | 只做 SQLite 读写：统计、备份、删除 `dsh-auth-*`、校验 |
| `dsh-cookie-cleanup.cmd` | 双击手动清理 |
| `dsh-cookie-report.cmd` | 双击只读报告（`-DryRun`） |
| `start-dsh-clean.cmd` | 先清理再启动 DeepSeek Harness |
| `install-autoclean.cmd` | 双击安装登录后自动清理 |
| `remove-autoclean.cmd` | 双击卸载自动清理 |
| `install-task.ps1` | 安装/停止/卸载/查看自动清理（计划任务或登录启动） |
| `tests\check.ps1` | Fast/Full 检查：语法、help 覆盖、控制台断言扫描、测试套件 |
| `tests\run-tests.ps1` | 自测套件（由 `check.ps1` 调用；临时任务/watcher 会在结束后清理） |
| `tests\resolve-python.ps1` | 测试/检查共用的 Python 解析（与 `cleanup.ps1` 同序） |
| `tests\make-test-db.py` | 生成合成 Cookie 数据库，用于自测 |
| `tests\verify-db.py` | 校验数据库行数与完整性 |
| `backups\` | 自动备份目录 |
| `state\watcher.pid` | 运行中监视器的 PID（停止/卸载时清理） |
| `state\watcher.stop` | `-Stop` 临时写入的协作式停止请求（watcher 退出后删除） |
| `state\scheduled-task.vbs` | 计划任务的隐藏启动器（`wscript` 0 窗口，等待并传回 watcher 退出码）；不要手动删除，`-Status` 会检查 |
| `logs\cleanup.log` | 运行日志（UTF-8 BOM；超过 5 MB 自动归档为 `cleanup-*.log`，保留 5 份） |

---

## 9. 依赖

- Windows PowerShell 5.1 或 PowerShell 7；
- Python 3（带 `sqlite3` 标准库）。脚本会优先使用 DSH 自带的
  `~\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe`，
  找不到再找 PATH 里的 `python` / `py`；Microsoft Store 的
  `WindowsApps\python.exe` 转发器会被跳过，避免"打不开商店"式误报。
  Python 启动失败时日志会带上实际 Python 路径和 stderr，不会只写"无法读取"。
  Python 往 stderr 写内容不会触发脚本级终止，诊断分支能拿到原始输出。
  为避免每次报告都多等一次 Python 冷启动，默认不做预检；需要提前验证时加
  `-CheckPython`（会明确报告 Python 路径和 stderr）。
- 可用环境变量 `DSH_COOKIE_CLEANUP_PYTHON` 指定 Python 路径。

---

## 10. License

本项目使用 [MIT License](LICENSE) 开源，版权信息见 LICENSE 文件。
