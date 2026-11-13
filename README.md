# vps-init

[![测试](https://github.com/dagenduizhanga/vps-init/actions/workflows/ci.yml/badge.svg)](https://github.com/dagenduizhanga/vps-init/actions/workflows/ci.yml)

新 VPS 到手后的第一组操作：系统初始化、SSH 密钥登录、防火墙、系统更新。纯 Bash，不需要安装，运行结束不在服务器上留下程序文件。

## 快速开始

用 root 登录 VPS，运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh)
```

```text
  vps-init v0.4.0
  ──────────────────────────────────────────────
  主机        vps-sg-1 · Debian GNU/Linux 12 (bookworm)
  SSH         密码登录开启中 · root 允许密码 · 0 把公钥
  防火墙      UFW · 未启用
  时间        Etc/UTC · 自动校时 已同步
  ──────────────────────────────────────────────
  1  系统初始化      时区、自动校时、常用工具
  2  SSH 密钥登录    安装公钥，关闭密码登录
  3  防火墙          放行 SSH 后启用防火墙
  4  系统更新        升级全部软件包
  5  详细状态
  0  退出
```

顶部是服务器的当前状态。新机器按 1 → 2 → 3 的顺序走一遍即可。

## 功能

### 1. 系统初始化

- 时区默认 `Asia/Shanghai`，也可以指定，例如 `system Asia/Singapore`
- 开启自动校时：优先使用已有的 Chrony 或 systemd-timesyncd，都没有时安装 Chrony
- 补齐常用工具：curl、wget、git、vim、htop、unzip。某个包装不上（例如 RHEL 系的 htop 需要 EPEL）不影响其他包
- 重复运行会自动跳过已完成的项目

### 2. SSH 密钥登录

- 粘贴公钥或从 GitHub 账号导入；逐把校验、按指纹去重，误贴私钥会被拦下
- 关闭密码登录和键盘交互认证，root 只能用密钥登录
- 写入后用 `sshd -T` 按「root + 当前来源地址」核对最终生效值（包括 `Match` 规则），不符合就自动回滚
- 完成后请你新开窗口测试；回答登录失败会立即撤销

### 3. 防火墙

- 只使用已安装的 UFW 或 Firewalld，不擅自安装
- 先放行当前 SSH 端口：从本次连接读取，读不到就停止，不会猜默认的 22
- 启用前列出会被挡住的服务（例如 MoviePilot、Jellyfin 的端口），由你选择是否一并放行
- 能识别已有的各种放行写法：`22`、`22/tcp`、`OpenSSH`、`limit`、Firewalld 的 `ssh` 服务
- 完成后同样请你新开窗口测试，失败立即撤销。撤销时，如果防火墙是本工具启用的，会一并关闭

> Docker 映射的端口通常绕过本机防火墙；云服务商的安全组需要在服务商控制台另外配置。

### 4. 系统更新

升级全部软件包，执行前需要确认。过程中不会弹出配置文件冲突等交互提示，需要重启时会提醒。

## 命令行用法

每个功能都可以直接用子命令运行，跳过菜单：

```bash
I=https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh

bash <(curl -fsSL $I) system                   # 系统初始化（默认 Asia/Shanghai）
bash <(curl -fsSL $I) system Asia/Singapore    # 指定时区
bash <(curl -fsSL $I) ssh                      # SSH 向导
bash <(curl -fsSL $I) ssh 'ssh-ed25519 AAAA…'  # 直接添加公钥并关闭密码登录，不提问
bash <(curl -fsSL $I) ssh gh:你的GitHub用户名  # 导入该账号的全部公钥
bash <(curl -fsSL $I) firewall
bash <(curl -fsSL $I) update
bash <(curl -fsSL $I) status
```

### 撤销

```bash
bash <(curl -fsSL $I) ssh --undo       # 恢复原来的 SSH 登录方式（已添加的公钥保留）
bash <(curl -fsSL $I) firewall --undo  # 删除本工具添加的规则；防火墙是本工具启用的就一并关闭
```

### 固定版本

默认运行 `main` 分支的最新代码。想让每台服务器跑同一份代码，可以固定到某个提交或标签：

```bash
VPS_INIT_REF=<提交或标签> bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/<提交或标签>/install.sh)
```

## 安全设计

- **先说明，再确认**：改 SSH 登录方式、启用防火墙、系统更新这些高风险操作，都会先列出方案，确认后才执行；时区、校时这类低风险配置自动完成
- **只动自己的文件**：SSH 配置只写 `/etc/ssh/sshd_config.d/00-key-only.conf`，不改 `sshd_config`，也不覆盖别人的同名文件
- **先校验再生效**：校验失败自动回滚。修改记录保存在 `/var/lib/vps-init/`，撤销只还原本工具改过的内容
- **不删不猜**：不删除已有公钥和防火墙规则，不修改 SSH 端口，读不到端口时不猜默认值
- **输出可追溯**：软件包管理器等命令的完整输出写入 `/var/log/vps-init.log`

## 支持的系统

| 系统 | 支持情况 |
| --- | --- |
| Debian 11 / 12、Ubuntu 20.04 / 22.04 / 24.04、AlmaLinux 9 | 全部功能；SSH 模块在 CI 中逐一测试 |
| Rocky Linux 9 等其他 RHEL 9 系 | 预期与 AlmaLinux 9 相同，未单独测试 |
| 其他使用 APT / DNF / YUM / APK 的发行版 | 系统初始化、更新可用；SSH 模块需要 OpenSSH 8.2+，且 `sshd_config` 已包含 `sshd_config.d` |

需要 Bash 4+ 和 root 权限。

## 开发

```bash
bash tests/smoke.sh                # 冒烟测试，不需要 root、不修改系统
sudo bash tests/ssh.sh             # SSH 模块：在本机真实 sshd 上应用、撤销、回滚，结束后恢复
sudo python3 tests/interactive.py  # 交互流程：SSH 向导、主菜单、防火墙（需要 python3-pexpect）
```

```text
install.sh          远程启动器：下载源码到临时目录运行，结束后清理
vps-init.sh         命令入口与交互菜单
lib/common.sh       公共函数：界面输出、交互、任务执行、系统检测
modules/            system.sh · ssh.sh · firewall.sh，每个模块都能单独运行
tests/              冒烟测试、SSH 行为测试、交互测试，以及测试替身
ssh-key-only.sh     旧版入口，等同于 ssh 子命令
```

设计约定见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 旧版命令

早期的 `ssh-key-only.sh` 命令继续可用，等同于 `ssh` 子命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh)
```

0.3.x 留下的 SSH 和防火墙修改记录，可以直接用新版本的 `--undo` 撤销。
