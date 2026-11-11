# vps-init

轻量、模块化的 VPS 初始化工具。使用 Bash 编写，界面和说明以中文为主，必要的技术术语保留英文。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh)
```

指定功能：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) ssh
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) system
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) security
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) status
```

> 当前 `system` 和 `security` 是安全占位模块，明确提示尚未实现，不会修改系统。SSH 功能继续由原有向导提供。

## 交互菜单

不带参数启动后，可以选择 SSH 配置、系统初始化、安全加固或查看系统状态。

## 当前功能

### SSH 密钥登录

原有 `ssh-key-only.sh` 完整保留，支持：

- 粘贴一把或多把 SSH 公钥
- 从 GitHub 用户导入公钥
- 从 URL 获取公钥
- 校验公钥并按指纹去重
- 关闭密码登录并限制 root 使用密钥登录
- 检查 sshd 配置并支持 `--undo`

旧入口保持兼容：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh)
```

### 系统状态

```bash
bash vps-init.sh status
```

显示发行版、内核、架构、主机名和 SSH 服务状态。

## 项目结构

```text
vps-init/
├── install.sh
├── vps-init.sh
├── lib/common.sh
├── modules/ssh.sh
├── modules/system.sh
├── modules/security.sh
├── docs/ARCHITECTURE.md
└── ssh-key-only.sh
```

## 安全原则

- 有风险的系统修改必须先展示计划并取得确认。
- SSH 修改必须备份配置、验证配置，再重载服务。
- 不默认开启防火墙或修改 SSH 端口，避免远程锁定。
- 不自动删除用户已有 SSH 公钥。
- 未实现的模块明确提示，不执行伪操作。

## 开发路线

- [x] 统一入口、交互菜单和模块目录
- [x] 保留原有 SSH 功能入口
- [ ] 将 SSH 实现迁入模块并完善事务式回滚
- [ ] System：系统更新、时区和常用工具
- [ ] Security：UFW / Firewalld 检测与安全加固
- [ ] ShellCheck、Bats 和 GitHub Actions

## 本地运行

```bash
bash vps-init.sh
bash vps-init.sh ssh
bash vps-init.sh status
```
