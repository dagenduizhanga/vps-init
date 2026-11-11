# vps-init

轻量、模块化的 VPS 初始化工具。使用 Bash 编写，界面、提示和文档以中文为主，必要的技术术语保留英文。

## 快速开始

使用 root 登录 VPS 后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh)
```

也可以直接选择功能：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) ssh
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) system
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) security
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/install.sh) status
```

## 交互菜单

不带参数启动后，可以选择：

1. SSH 密钥登录与安全配置
2. 系统初始化
3. 安全加固
4. 查看系统状态

## 功能说明

### SSH 密钥登录

支持：

- 粘贴一把或多把 SSH 公钥
- 从 GitHub 用户导入公开公钥
- 从 HTTPS 地址获取公钥（限制下载大小和超时）
- 校验公钥并按指纹去重
- 关闭密码和键盘交互认证，限制 root 仅使用密钥登录
- SSH 配置语法和最终生效值检查
- 原配置备份、失败回滚和主动撤销
- 可重复执行；已存在的公钥不会重复添加

旧入口继续保留：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh)
```

撤销 SSH 配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh) --undo
```

撤销只恢复本工具管理的 SSH 配置，不删除已经添加的公钥。配置备份位于 `/var/lib/vps-init/ssh/`。

### 系统初始化

支持 Debian / Ubuntu（APT）、RHEL 系（DNF / YUM）和 Alpine（APK）常见包管理器：

- 查看系统、包管理器、时区和磁盘信息
- 更新系统软件包
- 设置系统时区
- 安装 curl、wget、git、vim、htop、unzip 等常用工具

每项系统变更都会先展示计划并要求确认。

命令示例：

```bash
bash vps-init.sh system status
bash vps-init.sh system update
bash vps-init.sh system timezone Asia/Singapore
bash vps-init.sh system tools
```

### 安全加固

- 查看 SSH 最终生效配置和监听端口
- 查看 UFW / Firewalld 状态
- 在确认后配置并启用已安装的防火墙
- 启用前自动放行检测到的 SSH TCP 端口，并优先选择 SSH 入站网卡对应的 Firewalld 区域
- 记录本工具新增的规则，支持只撤销本工具添加的规则，不关闭原有防火墙

**重要：** 防火墙启用可能影响远程访问。请保持当前 SSH 会话，确认云厂商安全组也放行 SSH 端口，并在另一个终端验证登录。工具不会自动安装防火墙，也不会擅自更改 SSH 端口。

命令示例：

```bash
bash vps-init.sh security status
bash vps-init.sh security firewall
bash vps-init.sh security --undo
```

## 项目结构

```text
vps-init/
├── install.sh
├── vps-init.sh
├── lib/
│   └── common.sh
├── modules/
│   ├── ssh.sh
│   ├── system.sh
│   └── security.sh
├── tests/
│   └── smoke.sh
├── docs/
│   └── ARCHITECTURE.md
└── ssh-key-only.sh
```

## 安全原则

- 不默认开启防火墙或修改 SSH 端口。
- 不自动删除用户已有 SSH 公钥。
- 不覆盖非本工具创建的 SSH drop-in 配置。
- SSH 配置先备份、原子替换、校验后再重载。
- 失败时尝试恢复原配置；撤销时只恢复本工具管理的内容。
- 所有系统变更都必须经过明确确认。
- 不支持的系统或缺失的工具会明确报错，不伪装成功。

## 支持范围与限制

- 需要 Bash 4+、root 权限。
- SSH 模块要求 OpenSSH 支持 `sshd_config.d`，并且主配置已包含该目录。
- 系统更新支持 APT、DNF、YUM、APK；不同发行版的软件包名称可能存在差异。
- 防火墙模块仅管理本机 UFW / Firewalld，不管理云厂商安全组。
- 当前不会自动处理云镜像的特殊 SSH 策略、SELinux 自定义策略或复杂的 `Match` 规则。

## 测试

本地执行：

```bash
bash tests/smoke.sh
```

GitHub Actions 自动执行 ShellCheck、Bash 语法检查和模块冒烟测试。

## 开发路线

- [x] 中文交互菜单与统一命令入口
- [x] SSH 模块兼容入口和旧命令兼容
- [x] SSH 配置备份、验证、失败回滚和撤销
- [x] 系统初始化模块
- [x] 安全状态检查与防火墙配置
- [x] 基础自动化测试与 CI
- [ ] 多发行版真实 VPS 测试
- [ ] SSH / 防火墙故障注入测试
