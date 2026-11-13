#!/usr/bin/env python3
"""真实防火墙端到端测试：在本机真实的 UFW 或 Firewalld 上执行启用、复查、撤销、测试失败回滚。

会启用并关闭本机防火墙，只应在一次性环境中运行：CI 虚拟机，或者用
`unshare --net` 隔离出的网络命名空间（仅 UFW）。需要 root 和 python3-pexpect。

    sudo unshare --net -- python3 tests/firewall_real.py   # 本地：隔离的网络里测 UFW
    sudo python3 tests/firewall_real.py                    # CI：直接在虚拟机上测
"""
import os
import shutil
import subprocess
import sys
import tempfile
import traceback

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_DIR = "/var/lib/vps-init/security"
WORK = tempfile.mkdtemp()


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def backend():
    if shutil.which("ufw"):
        return "ufw"
    if shutil.which("firewall-cmd"):
        return "firewalld"
    sys.exit("没有安装 UFW 或 Firewalld")


BACKEND = backend()


def env(port):
    return dict(os.environ, NO_COLOR="1", TERM="dumb", VPS_INIT_LOG=os.path.join(WORK, "vps-init.log"),
                SSH_CONNECTION=f"203.0.113.5 50000 198.51.100.1 {port}")


def active():
    if BACKEND == "ufw":
        return sh("ufw", "status").stdout.startswith("Status: active")
    return sh("firewall-cmd", "--state").returncode == 0


def allowed(port):
    """用防火墙自己的命令确认端口是否放行（不经过 vps-init 的判断逻辑）。"""
    if BACKEND == "ufw":
        out = sh("ufw", "status").stdout if active() else sh("ufw", "show", "added").stdout
        return f"{port}/tcp" in out
    if active():
        zone = sh("firewall-cmd", "--get-default-zone").stdout.strip()
        runtime = sh("firewall-cmd", f"--zone={zone}", f"--query-port={port}/tcp").returncode == 0
        permanent = sh("firewall-cmd", "--permanent", f"--zone={zone}", f"--query-port={port}/tcp").returncode == 0
        service = port == 22 and sh("firewall-cmd", f"--zone={zone}", "--query-service=ssh").returncode == 0
        return (runtime and permanent) or service
    zone = sh("firewall-offline-cmd", "--get-default-zone").stdout.strip()
    return sh("firewall-offline-cmd", f"--zone={zone}", f"--query-port={port}/tcp").returncode == 0


def reset():
    """恢复成「防火墙未启用、没有本工具记录」的初始状态。"""
    shutil.rmtree(STATE_DIR, ignore_errors=True)
    if BACKEND == "ufw":
        sh("ufw", "--force", "reset")
        sh("ufw", "--force", "disable")
    else:
        sh("systemctl", "disable", "--now", "firewalld")
        zone = sh("firewall-offline-cmd", "--get-default-zone").stdout.strip()
        sh("firewall-offline-cmd", f"--zone={zone}", "--remove-port=2222/tcp")
    assert not active()


def spawn(port, *args):
    child = pexpect.spawn("bash", ["modules/firewall.sh", *args], cwd=ROOT, env=env(port),
                          encoding="utf-8", timeout=120)
    child.logfile_read = open(os.path.join(WORK, "last.log"), "w")
    return child


def finish(child):
    child.expect(pexpect.EOF)
    child.close()
    return child.exitstatus


def enable(port, answer_test):
    c = spawn(port)
    # 本机若有其他对外服务，会先问要不要一并放行；这里都不放行
    if c.expect(["要一并放行哪些", "确认执行"]) == 0:
        c.sendline("")
        c.expect("确认执行")
    c.sendline("y")
    c.expect("新窗口能连上吗")
    c.sendline(answer_test)
    return finish(c)


def check_enable_and_undo(port):
    reset()
    assert not allowed(port) or port == 22
    assert enable(port, "y") == 0
    assert active(), "防火墙应已启用"
    assert allowed(port), f"{port}/tcp 应已放行"

    c = spawn(port)
    c.expect("无需修改")
    assert finish(c) == 0

    c = spawn(port, "--undo")
    c.expect("它是本工具启用的")
    c.expect("确认撤销")
    c.sendline("y")
    c.expect("已撤销本工具的防火墙修改")
    assert finish(c) == 0
    assert not active(), "撤销后防火墙应关闭"
    if port != 22 or BACKEND == "ufw":
        assert not allowed(port), f"撤销后 {port}/tcp 规则应已删除"
    assert not os.path.exists(os.path.join(STATE_DIR, "firewall.state"))


def check_failed_test_reverts(port):
    reset()
    assert enable(port, "n") == 0
    assert not active(), "测试失败后防火墙应关闭"
    if port != 22 or BACKEND == "ufw":
        assert not allowed(port), f"测试失败后 {port}/tcp 规则应已删除"


def check_ufw_existing_rules():
    """已有的各种 SSH 放行写法都要能认出来，不重复添加规则。"""
    for rule in (["allow", "22"], ["allow", "OpenSSH"], ["limit", "22/tcp"]):
        reset()
        assert sh("ufw", *rule).returncode == 0, rule
        assert sh("ufw", "--force", "enable").returncode == 0
        before = sh("ufw", "show", "added").stdout
        c = spawn(22)
        c.expect("无需修改")
        assert finish(c) == 0, rule
        assert sh("ufw", "show", "added").stdout == before, f"{rule} 后不应再添加规则"


def main():
    if os.geteuid() != 0:
        sys.exit("需要 root 运行")
    print(f"后端：{BACKEND}")
    cases = [
        ("启用（SSH 22）→ 复查 → 撤销", lambda: check_enable_and_undo(22)),
        ("启用（SSH 2222）→ 复查 → 撤销", lambda: check_enable_and_undo(2222)),
        ("新窗口测试失败 → 立即撤销", lambda: check_failed_test_reverts(2222)),
    ]
    if BACKEND == "ufw" and os.path.exists("/etc/ufw/applications.d/openssh-server"):
        cases.append(("识别已有的 22 / OpenSSH / limit 规则", check_ufw_existing_rules))
    failed = 0
    try:
        for name, case in cases:
            try:
                case()
                print(f"  ✓ {name}")
            except Exception:
                failed += 1
                print(f"  ✗ {name}")
                print("      " + traceback.format_exc().strip().replace("\n", "\n      "))
                log = open(os.path.join(WORK, "last.log")).read()
                print("      ---- 终端输出 ----\n      " + log[-2000:].replace("\n", "\n      "))
    finally:
        reset()
        shutil.rmtree(WORK, ignore_errors=True)
    print(f"\n通过 {len(cases) - failed} 项，失败 {failed} 项")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
