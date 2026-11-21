# 开发机资源管理调研

2026-11-21。以下社区数字来自具体报告，不能用来推断发生率或当前版本表现。

## 三种容易混淆的负载

**一个会话可能启动多个进程。** 有 macOS 用户报告切换 Claude Code 会话后，之前的后端进程仍驻留。即使主进程用量正常，watcher、MCP server 和开发服务器也值得独立查看。父子关系和工作目录是归属线索，重新挂到系统进程的任务需要另找证据。[Claude Code #45507](https://github.com/anthropics/claude-code/issues/45507)

**磁盘空间至少要分开看 checkout 和会话记录。** 一位 Codex 用户报告临时目录积累 118 个副本、约 202 GB；另一份报告指出 worktree 可能保留未提交内容。还有用户报告子代理会话日志膨胀。按 Git 登记统计、按目录测量、检查本地改动回答的是三个不同的问题。依赖目录、构建产物以及 APFS 共享块会影响删除后的实际收益。[临时副本](https://github.com/openai/codex/issues/35383) · [未提交文件](https://github.com/openai/codex/issues/54891) · [会话日志](https://github.com/openai/codex/issues/34061)

**Docker 的空闲判定取决于运行中的容器。** Docker Desktop 的 Resource Saver 默认在没有运行容器五分钟后关闭 Linux VM。一个仍在运行的本地数据库就足以让这个条件不成立，即便应用层没有请求。拔电后先查还在跑什么，再决定哪些服务可停。对单台机器量化续航收益，需要记录拔电前后的实际负载和放电率。[Docker 官方机制](https://docs.docker.com/desktop/use-desktop/resource-saver/)

## 现有解决方案

| 项目 | 已覆盖的问题 | 对首版的启发 |
| --- | --- | --- |
| [claude-top](https://github.com/mbrummerstedt/claude-top) · MIT | 按 Claude 会话归属 CPU、内存、子进程和容器，展示遗留 worktree | 最接近的一体化方案。Claude 重度用户可以直接从它开始 |
| [MemBot](https://github.com/jimmymcjimbob/membot) · Apache-2.0 | macOS 菜单栏按 AI 工具会话归属资源，定位残留进程 | 同时使用 Claude 和 Codex 时，值得对照其会话识别和内存口径 |
| [Stats](https://github.com/exelban/stats) · MIT | 菜单栏查看系统 CPU、内存、磁盘和电池 | 适合先判断整机瓶颈 |
| [Worktrunk](https://worktrunk.dev/) · Apache-2.0 | 面向并行开发的 worktree 列举、切换、合并和移除 | 大量 checkout 的日常 Git 生命周期已有成熟入口 |
| [lazydocker](https://github.com/jesseduffield/lazydocker) · MIT | 终端中检查并操作 Docker 服务和容器 | 适合进一步诊断需要保留的容器 |
| [Colima](https://github.com/abiosoft/colima) · MIT | 可配置 CPU、内存等参数的本地容器运行时 | 可以给开发 VM 设资源预算，实际耗电仍需测量 |

## DevLoadBar 的范围

首版选择独立 Swift 菜单栏应用。它把 Codex 和 Claude 进程归属、指定仓库的工作区、按需目录测量和电池模式下的本地容器检查放进一个窗口。进程族归属目前只到工具级。后续最值得验证的是同一个工作目录中的进程、容器与会话能否可靠关联，以及这种关联能否帮助用户安全地回收空间。
