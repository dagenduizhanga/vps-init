# vps-init

新 VPS 初始化脚本。

## ssh-key-only.sh — SSH 只允许密钥登录

用 root 登录服务器，运行这一行，然后按提示操作：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh)
```

向导分四步：

1. **检查环境**：确认系统支持，并列出 root 已有的公钥。
2. **添加公钥**：粘贴公钥，或从 GitHub 账号导入。每一把都会校验；如果误贴了私钥会被拦下，可以连续添加多把。
3. **确认**：列出即将做的改动，你确认之前不会动任何东西。
4. **应用**：完成后会让你新开一个窗口测试密钥登录。如果回答没成功，会立即撤销，恢复密码登录。

### 准备公钥

- **Termius**：在 Keychain 里打开你的密钥，复制公钥（`ssh-ed25519` 开头的一行）。
- **电脑**：`cat ~/.ssh/id_ed25519.pub`。没有密钥的话，先运行 `ssh-keygen -t ed25519` 生成一把。

### 不提问的用法（适合自动化）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh) 'ssh-ed25519 AAAA... 备注'
```

参数也可以写成 `gh:你的GitHub用户名`（导入该账号的**全部**公钥），或者一个公钥文件的网址。

### 撤销

恢复系统原有的登录方式，已装的公钥保留：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagenduizhanga/vps-init/main/ssh-key-only.sh) --undo
```

### 原理

- 只写入 `/etc/ssh/sshd_config.d/00-key-only.conf`，不改 `sshd_config` 本身。文件名以 `00-` 开头，所以会排在 Ubuntu 云镜像自带的 `50-cloud-init.conf`（里面写着 `PasswordAuthentication yes`）之前生效。
- 写入后先用 `sshd -t` 检查语法，再用 `sshd -T` 核对最终生效值，都通过才重载 sshd；否则恢复原状。重载不会断开已有连接。
- 公钥按指纹去重，重复运行不会重复添加。
- 整个脚本包在一个函数里，下载完整、解析完才开始执行，网络中断时不会只跑半截。
- 需要 OpenSSH 8.2+（Debian 11+、Ubuntu 20.04+、RHEL/Rocky/Alma 9+）。更旧的系统会在第一步报错退出。

> 万一登录不上：只要原来的窗口还开着，在里面运行上面的撤销命令即可。窗口已经关了的话，用服务商网页上的 VNC 控制台登录，它不走 SSH，仍然可以用密码。
