# Coding Standards

这些是 review 阶段的判断题；机械项由 `tests\check.ps1` 检查。

## 文档

- `MANUAL.md` 是参数、退出码和行为的唯一权威；`README.md` 可保留机制和操作概览，细节以 MANUAL 为准。
- 文档声明必须对照代码；不要比实现更强的保证（顺序、范围、副作用、退出码）。
- `CHANGELOG.md` 只记录增量；不要硬编码可由套件生成的计数。

## 测试

- 断言行为或 ASCII 标记；不要匹配本地化控制台文本（包括先存变量再匹配）。
- 测试必须清理临时计划任务、watcher、目录；头部副作用声明要准确。
- 行为/参数变更必须带回归测试。

## 代码

- 恢复/删除路径保持 fail-closed；不要用 `SilentlyContinue` 吞掉回滚失败。
