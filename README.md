# Proxmox PVE Cloud Templates

![Proxmox](https://img.shields.io/badge/Proxmox%20VE-cloud--init-E57000)
![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420)
![Kernel](https://img.shields.io/badge/kernel-cloud%2Fvirtual-2F855A)

面向 Proxmox VE 的轻量 Cloud Image 构建仓库。默认基于官方 Debian `genericcloud` / Ubuntu `cloudimg`，保留官方 cloud/virtual kernel，不预置 root 密码。`minimal` 永远只安装 PVE 必要组件；`common` 默认安装常用工具，并默认启用 Docker、Speedtest、TCP 窗口调优 / BBR，可在 Action 中关闭。

标签：`proxmox`、`pve`、`cloud-init`、`debian-genericcloud`、`ubuntu-cloudimg`、`qemu-guest-agent`、`qcow2`、`minimal-image`

## 镜像档位

| 档位 | 目标 | 适合场景 |
| --- | --- | --- |
| `minimal` | 极小 PVE 基础模板 | 干净系统、后续用 cloud-init/Ansible 安装业务 |
| `common` | 基础模板 + 常用工具 | 日常 VPS、小服务、排障更方便 |

`minimal` 默认安装：

```text
sudo openssh-server cloud-init qemu-guest-agent cloud-guest-utils e2fsprogs
ca-certificates curl wget unzip less nano iproute2 iputils-ping
```

`common` 在 `minimal` 上额外安装：

```text
btop chrony git vim jq rsync dnsutils mtr-tiny traceroute
tcpdump lsof socat zip zstd bash-completion
```

`fastfetch` 会在目标发行版仓库可用时自动安装，并写入 root 的默认配置；Debian 13 可用。

可选功能只在 `common` 档位生效，`minimal` 会忽略这些开关并保持极简：

| 开关 | 默认 | 说明 |
| --- | --- | --- |
| `install_docker` | `true` | common 下添加 Docker 官方 APT 源并安装 Docker CE |
| `install_speedtest` | `true` | common + Debian 13 下添加 Ookla 源并安装 `speedtest` |
| `enable_bbr` | `true` | common 下写入 TCP 调优和 BBR sysctl 配置 |

## 安全策略

镜像不内置默认 root 密码。克隆 VM 时通过 PVE cloud-init 注入登录方式：

| 注入内容 | SSH 策略 |
| --- | --- |
| 只有 root 密码 | 允许 root 密码登录 |
| 有 SSH key | 禁用密码登录，只允许密钥 |
| SSH key 和 root 密码都有 | 禁用密码登录，只允许密钥 |
| 都没有 | 禁止远程登录，只能控制台处理 |

实现方式：镜像内置一次性 `pve-cloud-auth-mode.service`，在 `cloud-final.service` 后检查 `/root/.ssh/authorized_keys` 和 root 密码状态，然后写入 SSH 配置。

## 支持镜像

每次 GitHub Actions 会同时构建 `minimal` 和 `common` 两档，共 10 个 amd64 镜像：

| 系统 | `minimal` 文件名 | `common` 文件名 |
| --- | --- | --- |
| Debian 12 | `debian-12-genericcloud-amd64-pve-minimal.qcow2` | `debian-12-genericcloud-amd64-pve-common.qcow2` |
| Debian 13 | `debian-13-genericcloud-amd64-pve-minimal.qcow2` | `debian-13-genericcloud-amd64-pve-common.qcow2` |
| Ubuntu 22.04 LTS | `ubuntu-22.04-server-cloudimg-amd64-pve-minimal.qcow2` | `ubuntu-22.04-server-cloudimg-amd64-pve-common.qcow2` |
| Ubuntu 24.04 LTS | `ubuntu-24.04-server-cloudimg-amd64-pve-minimal.qcow2` | `ubuntu-24.04-server-cloudimg-amd64-pve-common.qcow2` |
| Ubuntu 26.04 LTS | `ubuntu-26.04-server-cloudimg-amd64-pve-minimal.qcow2` | `ubuntu-26.04-server-cloudimg-amd64-pve-common.qcow2` |

## GitHub Actions 构建

Fork 后进入 `Actions`，运行 `Build PVE Cloud Templates`。一次运行会构建全部 5 个系统的 `minimal` 和 `common` 镜像。

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `install_docker` | `true` | common 档位是否安装 Docker CE |
| `install_speedtest` | `true` | common + Debian 13 是否安装 Speedtest CLI |
| `enable_bbr` | `true` | common 档位是否启用 TCP 调优和 BBR sysctl 配置 |
| `publish_release` | `true` | 是否发布 GitHub Release |
| `apply_updates` | `true` | 是否在构建时执行系统更新 |

Release 标签格式：

```text
pve-cloud-templates-YYYY.MM.DD
```

工作流固定使用 `ubuntu-22.04` runner，避免 `ubuntu-latest` 上 libguestfs/QEMU 行为变化影响构建。构建产物只上传最终 `.qcow2` 和 `.qcow2.sha256`。

## 本地构建

在 Ubuntu 22.04 / 24.04 上运行：

```bash
chmod +x ./build-pve-cloud-image.sh

IMAGE_ID=debian13 IMAGE_PROFILE=minimal ./build-pve-cloud-image.sh
IMAGE_ID=debian13 IMAGE_PROFILE=common ./build-pve-cloud-image.sh
```

常用变量：

```bash
IMAGE_ID=debian13 \
IMAGE_PROFILE=common \
WORKDIR=/tmp/pve-cloud-build/debian13-common \
IMAGE_DISK_SIZE=4G \
INSTALL_DOCKER=true \
INSTALL_SPEEDTEST=true \
ENABLE_BBR=true \
APPLY_UPDATES=true \
./build-pve-cloud-image.sh
```

`INSTALL_DOCKER`、`INSTALL_SPEEDTEST`、`ENABLE_BBR` 只在 `IMAGE_PROFILE=common` 时生效。

`IMAGE_DISK_SIZE` 默认值为 `4G`；Ubuntu 26.04 默认使用 `6G`，用于给系统更新保留解包空间。最终镜像仍会经过 sparse 压缩。

`ENABLE_BBR=true` 会写入 `/etc/sysctl.d/99-pve-tcp-tune.conf`。该配置启用 BBR 拥塞控制，并调整 TCP/UDP 缓冲区、窗口缩放和队列调度参数：

```text
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
```

这组参数适合通用 KVM/VPS 场景，但并不是所有业务都一定需要。对延迟敏感、吞吐敏感或有明确网络基准要求的服务，建议基于实际压测结果调整或关闭。

支持的 `IMAGE_ID`：

```text
debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604
```

## 在 PVE 上导入模板

下面示例导入 Debian 13 `minimal` 镜像，创建 VMID `9013` 的模板。

```bash
REPO="mihomoQ/proxmox-templates"
PROFILE="minimal"
RELEASE_TAG="${RELEASE_TAG:-}"

if [ -z "${RELEASE_TAG}" ]; then
  RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "${RELEASE_TAG}" ] || { echo "无法获取最新 Release 标签"; exit 1; }

BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
VMID=9013
NAME="debian-13-${PROFILE}-template"
IMAGE="debian-13-genericcloud-amd64-pve-${PROFILE}.qcow2"
IMAGE_DIR="/root/cloud-image"

if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi
[ -n "${STORAGE}" ] || { echo "无法自动识别 PVE 存储名"; exit 1; }

mkdir -p "${IMAGE_DIR}"
cd "${IMAGE_DIR}"
wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -

qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 1024 \
  --cores 1

qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ipconfig0 ip=dhcp
qm template "${VMID}"
```

如果你的存储导入后磁盘名不是 `vm-${VMID}-disk-0`，先执行：

```bash
qm config "${VMID}"
```

查看 `unused0` 对应磁盘名后再挂载到 `scsi0`。

## 克隆 VM

密钥登录，推荐：

```bash
qm clone 9013 101 --name debian13-test --full 1 --storage "${STORAGE}"
qm set 101 --ciuser root
qm set 101 --sshkeys ~/.ssh/id_ed25519.pub
qm start 101
```

密码登录，适合临时或内网场景：

```bash
qm clone 9013 102 --name debian13-password-test --full 1 --storage "${STORAGE}"
qm set 102 --ciuser root
qm set 102 --cipassword "请改成强密码"
qm start 102
```

如果同时设置 `--sshkeys` 和 `--cipassword`，镜像首次启动后会禁用 SSH 密码登录，只允许密钥。

查看 IP：

```bash
qm guest cmd 101 network-get-interfaces
```

检查 guest agent：

```bash
systemctl status qemu-guest-agent --no-pager
```

## 设计取舍

- 默认保留官方 cloud/virtual kernel，不主动安装 `linux-image-amd64` / `linux-generic`。
- 默认使用官方 cloud image，不从 ISO 安装，构建过程可复现。
- `minimal` 默认不包含 Docker、Speedtest、TCP 窗口调优 / BBR；这些功能只在 `common` 中默认开启，并可手动关闭。
- TCP 调优参数由镜像构建脚本写入固定的 sysctl 配置文件。
- 默认清理 APT 缓存、cloud-init 状态、日志、文档和 man/info，最后用 `virt-sparsify --compress` 压缩 qcow2。
- 默认禁用 `deb-src`，关闭 cloud-init 首次启动自动 package upgrade，减少首次启动不可控耗时。
