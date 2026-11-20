# optim_perf — Linux 桌面性能运维工具集

诊断并分层优化 Linux 桌面环境的 CPU / 内存问题。纯 Bash 实现，零第三方依赖，
配合 systemd user 定时器提供每日报告。

## 组件

| 文件 | 说明 |
|---|---|
| `cpuopt.sh` | CPU 分析与优化：报告、扫描失控进程、节流（renice）、击杀失控进程、bazel 编译清理、watch 监控 |
| `memopt.sh` | 内存分析与优化：报告、停闲置 bazel server、清页缓存、swap 整理、应用优雅重启、watch 监控 |
| `sandboxgc.sh` | Cursor `cursorsandbox` 泄漏进程的检测与回收（进程/线程压力报告、每小时自动回收定时器） |
| `optlib.sh` | 三个脚本共用的公共库（日志、确认、dry-run、定时器安装等） |
| `systemd/` | user 级 systemd 定时器单元（每日报告 / 每小时沙箱回收） |
| `hdmi-monitor-fix.md` | HDMI 外接显示器黑屏的根因分析与修复 runbook |

## cpuopt.sh 模式

| 命令 | 说明 |
|---|---|
| `./cpuopt.sh` （无参数） | 报告 + 安全自动层（仅报告，不做任何动作） |
| `./cpuopt.sh --report` | 纯分析报告，零副作用 |
| `./cpuopt.sh --scan [HOURS]` | 列出累计 CPU 时间超过 HOURS 的进程（默认 8） |
| `./cpuopt.sh --throttle PID` | 对持续繁忙的非交互进程 renice +15（可逆） |
| `./cpuopt.sh --unthrottle PID` | 恢复 nice 0 |
| `./cpuopt.sh --kill PID` | SIGTERM 确认的失控进程（需确认或 `--yes`） |
| `./cpuopt.sh --stop-bazel-thrash` | bazel 构建已失联时停止残留编译进程 |
| `./cpuopt.sh --watch [SEC]` | 每 SEC 秒循环报告（默认 60） |
| `./cpuopt.sh --install-timer` | 安装每日报告 systemd user 定时器 |

## memopt.sh 模式

| 命令 | 说明 |
|---|---|
| `./memopt.sh` （无参数） | 报告 + 安全自动层：**会停止闲置的 bazel server JVM**（无损，下次构建自动重建）。注意与 `cpuopt.sh` 的无参数模式语义不同 |
| `./memopt.sh --report` | 纯分析报告，零副作用 |
| `./memopt.sh --stop-bazel` | 停止闲置的 bazel server JVM |
| `./memopt.sh --clean` | 清除页缓存（需 sudo） |
| `./memopt.sh --trim-swap` | swap off/on 循环，把陈旧 swap 页拉回内存（先做安全检查） |
| `./memopt.sh --restart APP` | 优雅重启 `chrome` \| `feishu` \| `cursor` |
| `./memopt.sh --watch [SEC]` | 每 SEC 秒循环报告，低内存时告警（默认 60） |
| `./memopt.sh --install-timer` | 安装每日报告 systemd user 定时器 |

## sandboxgc.sh 模式

解决 Cursor 的 `cursorsandbox` 辅助进程泄漏：每执行一次 agent 命令就泄漏一对
`--policy` / `--run-proxy` 且从不回收，每个占 15 个线程。数千个泄漏会给 14 核机器
叠加 3 万线程，导致 `ps`、`top`、系统监视器等遍历 `/proc` 的工具从 0.1 秒劣化到 5–7 秒。

泄漏进程的判据很干净：**没有子进程、累计 CPU 时间为 0、且父进程已不是当初拉起它的终端**。

| 命令 | 说明 |
|---|---|
| `./sandboxgc.sh` （无参数） | 仅报告，零副作用（与 `cpuopt.sh` 一致） |
| `./sandboxgc.sh --report` | 泄漏概览 + 系统进程/线程压力 + 可回收清单 |
| `./sandboxgc.sh --report --json` | 同上，机器可读 JSON |
| `./sandboxgc.sh --gc` | 回收，逐条确认；`--yes` 跳过确认 |
| `./sandboxgc.sh --watch [SEC]` | 每 SEC 秒循环报告泄漏增长（默认 60） |
| `./sandboxgc.sh --install-timer` | 安装每小时自动回收的 systemd user 定时器 |

专属选项：

- `--min-age SEC` — 只回收年龄超过 SEC 的沙箱（默认 3600）
- `--max-cpu JIFFIES` — 只回收累计 CPU 时间不超过该值的沙箱（默认 0，即从未执行过命令）
- `--grace SEC` — SIGTERM 到升级 SIGKILL 的宽限期（默认 5）
- `--orphans-only` — 只回收 `ppid=1` 的，跳过被 `systemd --user` 收养的
- `--threshold N` — `--watch` 的沙箱数量告警阈值（默认 300）

## 公共选项

- `--top N` — top 表格行数（默认 15）
- `--threshold PCT` — watch 告警阈值
- `--yes` — 跳过确认（sudo 类操作仍需密码）
- `--dry-run` — 只打印将执行的动作
- `-h, --help` — 帮助

## 安全护栏

- 只操作 `$USER` 自己拥有的进程。
- 交互进程（GNOME Shell、Xorg、终端、输入法等）永不被节流或击杀。
- 先 SIGTERM；SIGKILL 仅在 30 秒宽限后且经明确同意。
- `--trim-swap` 先检查可用内存是否够把 swap 全部拉回 RAM，不够则拒绝执行。
- `sandboxgc.sh` 只考虑名字精确等于 `cursorsandbox` 的进程，且**有子进程或有非零 CPU
  时间的一律不回收**（说明它正在驱动一条命令）；脚本自身的祖先链被排除。
- 所有动作写入日志：`~/.local/share/{cpuopt,memopt,sandboxgc}.log`。

## 定时任务

```bash
./cpuopt.sh --install-timer   # 每日 09:30 CPU 报告
./memopt.sh --install-timer   # 每日 09:00 内存报告
./sandboxgc.sh --install-timer  # 每小时回收泄漏沙箱（带 5 分钟随机延迟）
journalctl --user -u cpuopt-report.service     # 查看报告
journalctl --user -u sandboxgc-gc.service      # 查看回收记录
```

单元模板在 `systemd/`，安装时经 sed 注入脚本绝对路径。`Persistent=true`，
错过的触发点开机后会补跑。`sandboxgc` 用小时级频率是因为实测泄漏速率可达每分钟
数个，日级回收会重新累积到数千。

## 配置覆盖（可选）

应用路径与进程家族分类规则内置默认值。如需覆盖，创建
`~/.config/perfopt/apps.conf`（格式见文件内注释），两个脚本启动时自动加载。

## 开发

```bash
shellcheck cpuopt.sh memopt.sh sandboxgc.sh optlib.sh   # 零告警是硬性要求
bats tests/                                             # 单元测试（需 bats-core）
```
