# optim_perf 项目优化计划

**项目现状**：约 900 行 Bash 的桌面性能运维工具集（`cpuopt.sh` 430 行 + `memopt.sh` 469 行 + 4 个 systemd unit + 1 份 HDMI 排查文档），无 git、无 README、无测试。已与用户确认：以下 5 个阶段全部纳入，按序实施。

---

## 阶段 0：工程化基础（先做，让后续改动可回溯）

1. `git init` + `.gitignore`，先提交一份当前原始版本作为基线，之后每阶段单独提交。
2. 新建 `README.md`：项目用途、每个模式的说明（从脚本头部注释整理）、安全护栏（只动 `$USER` 进程、交互进程保护、SIGTERM 优先）、systemd 定时器安装方式、日志位置。
3. 加 `.editorconfig` 和 shellcheck 配置；对两个脚本跑 shellcheck 修到零告警（代码里已有内联 disable，说明环境可用）。

## 阶段 1：去重 — 抽公共库 `optlib.sh`

两个脚本有约 100 行逐行重复的代码，抽成被 `source` 的 `optlib.sh`，**保留两个脚本入口不变**（不合并成单脚本，避免破坏已安装的 systemd unit）：

- `log` / `die` / `confirm` / `run_or_dry`（cpuopt.sh:46-71 vs memopt.sh:39-66）
- `usage()` 改为通用实现：不再用 `sed -n '3,26p'` 按行号切片（头部注释一改动帮助就错位），改为在脚本内用标记对（如 `# <<usage` / `# usage>>`）定界
- `action_install_timer` 泛化为 `install_timer <unit-prefix> <script-name>`（cpuopt.sh:351-373 vs memopt.sh:389-413，逻辑完全一致）
- watch 循环骨架、`main` 参数解析公共部分（`--top/--threshold/--yes/--dry-run/--watch/-h`）
- 消除 cpuopt.sh 内部 `to_secs()` 的重复定义（133-140 与 170-177）

## 阶段 2：健壮性修复

1. **`/proc/$pid/stat` 解析坑**（cpuopt.sh:232-234、memopt.sh:226）：`awk '{print $14+$15}'` 在 `comm` 含空格时字段错位。修复：先剥离括号内的 comm 再取字段。
2. **日志治理**：`log()` 加 `flock` 防多实例（watch + timer）并发写坏行；加简单轮转（如超过 5MB 时 rename 保留一份旧文件）。
3. **扩充交互进程保护名单**（cpuopt.sh:220）：补充 `ibus-*`、`Xwayland`、`xdg-desktop-portal*`、显卡 helper 等常见桌面关键进程，降低误杀面。
4. **`--scan` 参数校验收紧**（cpuopt.sh:389）：`^[0-9.]+$` 会放过 `8.8.8.8`，改为合法小时数校验（正数、且拒绝多段式输入）。
5. **auto 模式语义对齐**：memopt 的无参数模式会静默 `action_stop_bazel`（memopt.sh:460，实际 kill 进程且不经过 confirm），cpuopt 的无参数模式是纯报告。保留 memopt 的设计意图（头部注释已声明），但在 README 中明确标注差异；给 auto 模式下的 stop-bazel 增加 `confirm`（非交互/timer 环境下 confirm 会自动拒绝，行为退化为报告——这与 cpuopt 一致且更安全）。
6. **`confirm()` 无 tty 环境告警**：从 `/dev/tty` 读取失败时输出一行提示（当前静默失败）。

## 阶段 3：性能优化

1. **`print_swap_consumers` 单遍化**（memopt.sh:169-177）：当前对每个 `/proc/[0-9]*/status` fork 两个 awk，几百进程就是几百次 fork；改为单个 awk 进程扫全部文件。
2. **`find_user_pids` 消除逐 pid fork**（memopt.sh:211-222）：当前每个 pid 起一次 `tr`；改为一次 `ps -u "$USER" -o pid=,args=` + awk 过滤，或直接 `pgrep -u "$USER" -f`。
3. **采样并行化**（memopt.sh:251-258）：`action_stop_bazel` 对多个候选 pid 串行各 `sleep 2`；改为所有 pid 的 t1 先采样、统一 `sleep 2`、再采 t2（采样窗口共享，总耗时从 N×2s 降为 2s）。
4. **`cpu_stats` 去掉 `vmstat 1 2` 的固定 1 秒消耗**（cpuopt.sh:82）：改读 `/proc/stat` 差分；watch 模式下与上一轮缓存的上次采样做差，报告模式下用 0.5s 短间隔采样（可接受精度损失换取更快的报告输出）。

## 阶段 4：可移植性 — 硬编码配置化

1. 应用路径与进程家族分类规则抽到顶部可配置区 + 可选配置文件 `~/.config/perfopt/apps.conf`（内置默认值，配置文件存在则覆盖）。涉及 memopt.sh:311-313（app 二进制路径）、cpuopt.sh:142-148 与 memopt.sh:133-140（家族分类正则）。
2. `print_recommendations` 从静态 heredoc（cpuopt.sh:193-210、memopt.sh:186-202）改为基于实测数据动态生成：仅在实际存在对应特征时输出对应建议（如确有累计 CPU 超阈值的进程才提示 --scan/--kill，确有 swap 消耗者才提示扩容）。

## 阶段 5：功能延伸

1. **HDMI 修复脚本化**：依据 `hdmi-monitor-fix.md` 117-140 行的"mutter 双重 apply"workaround，新增 `hdmi-fix.sh`（走 D-Bus 调用 `org.gnome.Mutter.DisplayConfig` 两次 apply），并纳入 README 与 optlib 的公共护栏。
2. **`--json` 机器可读输出**：report 模式新增 `--json` 标志，输出 summary/top/families/scan 的 JSON，便于其他工具消费（纯 awk/jq-free 实现）。
3. **bats 测试**：为纯函数补测试（`to_secs`、`mem_fields`、家族分类、`/proc/stat` 解析修复、usage 提取），测试文件放 `tests/`，可用桩 `/proc` fixture 目录测试 awk 逻辑；在 README 说明运行方式。

---

## 验证方式

- 每阶段后跑 `shellcheck cpuopt.sh memopt.sh optlib.sh hdmi-fix.sh` 零告警。
- `./cpuopt.sh --report`、`./memopt.sh --report`、`--dry-run` 各动作、`-h` 输出人工核对不回归。
- 阶段 3 的性能改动用前后耗时对比验证（如 swap consumers 段的输出时间）。
- 阶段 5 的 bats 测试全部通过。

## 涉及文件

新建：`optlib.sh`、`README.md`、`hdmi-fix.sh`、`tests/`、`.gitignore`、`.editorconfig`、shellcheck 配置
修改：`cpuopt.sh`、`memopt.sh`、（`systemd/` 单元不动）
