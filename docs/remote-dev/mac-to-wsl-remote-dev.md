# Mac 远程使用 Windows 机器里的 WSL 进行模型训练和开发

目标：把这台 Windows 机器当作一台“带 GPU 的 Linux 开发服务器”使用。日常从 Mac 通过 SSH、VS Code Remote SSH、JupyterLab 进入 WSL，不依赖远程桌面，不关心 Windows 桌面内容。

## 1. 推荐架构

默认推荐：

```text
Mac
  -> Tailscale 私有网络
    -> Windows 宿主机
      -> 端口转发
        -> WSL Ubuntu 的 SSH 服务
          -> CUDA / Conda / Python / Docker / 训练任务
```

为什么默认不直接把 Tailscale 装进 WSL：

- Tailscale 官方把 WSL2 内运行 Tailscale 视为更进阶的场景。
- 如果 Windows 宿主和 WSL 内同时运行 Tailscale，可能遇到封包尺寸/MTU 相关问题。
- 更稳妥的做法是：Tailscale 跑在 Windows，WSL 只提供 SSH 开发环境，Windows 做一层轻量端口代理。

高级可选架构：

```text
Mac
  -> Tailscale
    -> WSL 内的 Tailscale
      -> WSL SSH
```

这条路径更干净，但更依赖 WSL2 网络、systemd、tailscaled 的启动稳定性。除非你明确想把 WSL 当成完全独立的 tailnet 节点，否则建议先用默认架构。

## 2. 前置条件

Windows 机器：

- Windows 11 或较新的 Windows 10。
- 已安装 WSL2，建议 Ubuntu 22.04 或 24.04。
- 如需 GPU 训练，Windows 端安装支持 WSL 的 NVIDIA 驱动。
- Windows 管理员权限，用于配置端口转发和防火墙。
- Tailscale 已登录同一个 tailnet。

Mac：

- 安装 Tailscale 并登录同一个 tailnet。
- 安装 OpenSSH 客户端，macOS 自带。
- 推荐安装 VS Code 或 Cursor，并安装 Remote SSH 扩展。

WSL Ubuntu：

- 启用 systemd。
- 安装 OpenSSH Server。
- 安装开发环境，例如 Conda、uv、Python、CUDA/PyTorch、Docker、tmux、JupyterLab。

## 3. Windows 上安装和准备 WSL

在 Windows PowerShell 中运行：

```powershell
wsl --install
wsl --update
wsl --status
```

如果还没有 Ubuntu，可以安装：

```powershell
wsl --install -d Ubuntu-24.04
```

进入 Ubuntu：

```powershell
wsl -d Ubuntu-24.04
```

如果你的发行版名称不是 `Ubuntu-24.04`，先查看实际名称：

```powershell
wsl -l -v
```

后续脚本里的 `$Distro` 要改成这里显示的发行版名称。

在 WSL 中确认系统信息：

```bash
lsb_release -a
uname -a
```

## 4. 在 WSL 中启用 systemd

在 WSL Ubuntu 内编辑 `/etc/wsl.conf`：

```bash
sudo nano /etc/wsl.conf
```

写入：

```ini
[boot]
systemd=true
```

回到 Windows PowerShell，重启 WSL：

```powershell
wsl --shutdown
wsl -d Ubuntu-24.04
```

在 WSL 中验证：

```bash
systemctl is-system-running
```

如果显示 `running`、`degraded` 或能够正常执行 `systemctl status`，通常就可以继续。

## 5. 在 WSL 中安装和配置 SSH

在 WSL Ubuntu 内运行：

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
sudo systemctl status ssh
```

建议使用 SSH key，不建议用密码登录。

在 Mac 上如果还没有 SSH key：

```bash
ssh-keygen -t ed25519 -C "mac-to-wsl"
```

把 Mac 的公钥加入 WSL。可以先在 Mac 上查看：

```bash
cat ~/.ssh/id_ed25519.pub
```

然后在 WSL 中追加到 `~/.ssh/authorized_keys`：

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

可选：关闭密码登录。在 WSL 中编辑：

```bash
sudo nano /etc/ssh/sshd_config
```

确认或加入：

```text
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
```

重启 SSH：

```bash
sudo systemctl restart ssh
```

## 6. 在 Windows 上安装 Tailscale

在 Windows 上安装 Tailscale，登录你的账号，并确认 Mac 和 Windows 都在同一个 tailnet。

Windows PowerShell 中查看 Windows 的 Tailscale IPv4：

```powershell
& "$env:ProgramFiles\Tailscale\tailscale.exe" ip -4
```

也可以在 Tailscale 管理后台开启 MagicDNS。开启后，Mac 可以用类似下面的主机名访问：

```text
windows-hostname.tailnet-name.ts.net
```

## 7. 把 Windows 的 Tailscale 端口转发到 WSL SSH

WSL2 的 IP 可能会变化，所以建议用一个 PowerShell 脚本自动刷新端口代理。

在 Windows 管理员 PowerShell 中创建目录：

```powershell
New-Item -ItemType Directory -Force C:\Scripts
```

创建文件：

```powershell
notepad C:\Scripts\update-wsl-ssh-portproxy.ps1
```

写入：

```powershell
$ErrorActionPreference = "Stop"

$Distro = "Ubuntu-24.04"
$ListenPort = 2222
$TailscaleExe = "$env:ProgramFiles\Tailscale\tailscale.exe"

$WslIp = (wsl.exe -d $Distro hostname -I).Trim().Split()[0]
$TailscaleIp = (& $TailscaleExe ip -4).Trim()

if (-not $WslIp) {
    throw "Cannot detect WSL IP"
}

if (-not $TailscaleIp) {
    throw "Cannot detect Tailscale IPv4"
}

netsh interface portproxy delete v4tov4 listenaddress=$TailscaleIp listenport=$ListenPort 2>$null
netsh interface portproxy add v4tov4 listenaddress=$TailscaleIp listenport=$ListenPort connectaddress=$WslIp connectport=22

$RuleName = "WSL SSH via Tailscale"
$ExistingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

if ($ExistingRule) {
    $ExistingRule | Remove-NetFirewallRule
}

New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress $TailscaleIp `
    -LocalPort $ListenPort

Write-Host "Forwarding $TailscaleIp`:$ListenPort -> $WslIp`:22"
```

执行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\Scripts\update-wsl-ssh-portproxy.ps1
```

查看端口代理：

```powershell
netsh interface portproxy show all
```

### 可选：开机自动刷新端口代理

WSL IP 变化时，端口代理需要刷新。可以创建计划任务，让 Windows 登录时自动运行脚本。

管理员 PowerShell：

```powershell
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\Scripts\update-wsl-ssh-portproxy.ps1"
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
Register-ScheduledTask -TaskName "Update WSL SSH PortProxy" -Action $Action -Trigger $Trigger -Principal $Principal -Force
```

也可以在 Windows 重启、WSL 重启、Tailscale 重新登录后手动运行脚本一次。

## 8. 从 Mac 测试 SSH

先确认 Mac 已连接 Tailscale：

```bash
tailscale status
```

用 Windows 的 Tailscale IP 连接：

```bash
ssh -p 2222 your-wsl-user@100.x.y.z
```

如果启用了 MagicDNS：

```bash
ssh -p 2222 your-wsl-user@windows-hostname.tailnet-name.ts.net
```

成功后，你应该直接进入 WSL 的 Linux shell，而不是 Windows shell。

## 9. 配置 Mac 的 SSH Host

在 Mac 上编辑 `~/.ssh/config`：

```sshconfig
Host wsl-gpu
    HostName windows-hostname.tailnet-name.ts.net
    Port 2222
    User your-wsl-user
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

之后连接只需要：

```bash
ssh wsl-gpu
```

## 10. VS Code / Cursor Remote SSH

Mac 上安装：

- VS Code 或 Cursor。
- Remote SSH 扩展。

打开命令面板：

```text
Remote-SSH: Connect to Host...
```

选择：

```text
wsl-gpu
```

连接后，VS Code Server 会安装在 WSL 用户目录下。之后你可以直接打开 WSL 里的项目目录，例如：

```bash
mkdir -p ~/projects
cd ~/projects
git clone <your-repo>
```

日常体验会像使用远程 Linux 服务器：

- 代码编辑在 Mac。
- 终端运行在 WSL。
- Python、Conda、CUDA、PyTorch 都使用 WSL 环境。
- 训练进程实际跑在 Windows 机器的 GPU 上。

## 11. 配置训练环境

### 基础工具

```bash
sudo apt update
sudo apt install -y build-essential git curl wget tmux htop nvtop unzip
```

### 检查 GPU

在 WSL 中运行：

```bash
nvidia-smi
```

如果能看到 GPU、驱动版本和显存信息，说明 WSL GPU 通道可用。

### Python 环境

推荐用 Miniforge、Micromamba、uv 或 Conda 管理环境。示例：

```bash
mkdir -p ~/projects
cd ~/projects
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
```

安装 PyTorch 时建议根据当前 CUDA/驱动版本去 PyTorch 官网选择命令，避免 CUDA 版本不匹配。

### 长任务用 tmux

```bash
tmux new -s train
```

启动训练：

```bash
python train.py
```

断开 tmux：

```text
Ctrl-b d
```

重新进入：

```bash
tmux attach -t train
```

这样 Mac 断线或合盖时，训练不会因为 SSH 断开而停止。

## 12. JupyterLab 访问方式

在 WSL 中安装：

```bash
python -m pip install jupyterlab
```

推荐用 SSH 隧道，不把 Jupyter 直接暴露给网络。

在 Mac 上运行：

```bash
ssh -L 8888:localhost:8888 wsl-gpu
```

在 SSH 会话里的 WSL 中启动：

```bash
jupyter lab --ip=127.0.0.1 --port=8888
```

Mac 浏览器打开：

```text
http://localhost:8888
```

## 13. 可选高级方案：Tailscale 直接装进 WSL

如果你希望 WSL 自己成为 tailnet 节点，可以在 WSL 内安装 Tailscale，并从 Mac 直接 SSH 到 WSL 的 Tailscale IP。

架构：

```text
Mac -> Tailscale -> WSL Tailscale IP -> WSL SSH
```

注意事项：

- 不建议 Windows 宿主机和 WSL 内同时承担同一访问路径。
- 如果 Windows 宿主已经运行 Tailscale，优先用默认方案。
- 确认 WSL 已启用 systemd，否则 tailscaled 管理会麻烦。
- 如果遇到连接异常、无法握手、网络不稳定，先退回默认方案。

## 14. 安全建议

- 不要把 SSH、Jupyter、code-server 直接暴露到公网。
- SSH 优先使用 key，关闭密码登录。
- Windows 防火墙只允许 Tailscale IP 上的转发端口。
- 不要用 root 登录 SSH。
- 训练机器上如果有云厂商密钥、GitHub token、数据集凭证，建议用最小权限和单独账号。
- JupyterLab 优先通过 SSH 隧道访问。
- 给训练会话使用 tmux，避免网络断开导致任务中断。

## 15. 常见问题

### Mac SSH 连接超时

检查：

```bash
tailscale status
ssh -vvv wsl-gpu
```

Windows 上检查：

```powershell
& "$env:ProgramFiles\Tailscale\tailscale.exe" status
netsh interface portproxy show all
```

WSL 中检查：

```bash
systemctl status ssh
hostname -I
```

如果 WSL IP 变了，重新运行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\Scripts\update-wsl-ssh-portproxy.ps1
```

### 能 SSH，但 VS Code 连接失败

在 Mac 上先确认普通 SSH 可用：

```bash
ssh wsl-gpu
```

然后在 VS Code 中执行：

```text
Remote-SSH: Kill VS Code Server on Host...
```

再重新连接。

### nvidia-smi 在 WSL 里不可用

检查：

- Windows 是否安装了支持 WSL 的 NVIDIA 驱动。
- WSL 是否为 WSL2。
- Windows 是否需要重启。
- 在 Windows PowerShell 中运行 `wsl --update`。

### 训练中断

不要直接在裸 SSH 会话里跑长任务。使用：

```bash
tmux
```

或者把任务交给 `systemd`、`supervisor`、`nohup`、`accelerate launch` 等更适合长期运行的方式。

## 16. 快速验证清单

Windows：

```powershell
wsl --status
& "$env:ProgramFiles\Tailscale\tailscale.exe" status
netsh interface portproxy show all
```

WSL：

```bash
systemctl status ssh
nvidia-smi
```

Mac：

```bash
tailscale status
ssh wsl-gpu
```

进入 WSL 后：

```bash
whoami
pwd
nvidia-smi
tmux new -s smoke-test
```

## 17. 参考资料

- Microsoft WSL 安装文档：https://learn.microsoft.com/en-us/windows/wsl/install
- Microsoft WSL systemd 文档：https://learn.microsoft.com/en-us/windows/wsl/systemd
- Microsoft WSL 网络文档：https://learn.microsoft.com/en-us/windows/wsl/networking
- Microsoft WSL GPU 计算文档：https://learn.microsoft.com/en-us/windows/wsl/tutorials/gpu-compute
- Tailscale WSL2 文档：https://tailscale.com/docs/install/windows/wsl2
- Tailscale SSH 文档：https://tailscale.com/kb/1193/tailscale-ssh
- VS Code Remote SSH 文档：https://code.visualstudio.com/docs/remote/ssh
