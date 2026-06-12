#!/bin/bash
# ============================================================
# PVE Cloud Image builder
#
# Defaults are intentionally small:
# - keep the official cloud image kernel
# - do not bake a root password
# - install only PVE/cloud-init essentials unless IMAGE_PROFILE=common
# - enable Docker, Speedtest and TCP tuning by default only for common
# ============================================================

set -euo pipefail

IMAGE_ID="${IMAGE_ID:-debian13}"
IMAGE_PROFILE="${IMAGE_PROFILE:-minimal}"
WORKDIR="${WORKDIR:-$HOME/pve-cloud-build/${IMAGE_ID}-${IMAGE_PROFILE}}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
IMAGE_DISK_SIZE="${IMAGE_DISK_SIZE:-}"
ROOT_PARTITION="${ROOT_PARTITION:-/dev/sda1}"

INSTALL_HOST_TOOLS="${INSTALL_HOST_TOOLS:-true}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-false}"
DOWNLOAD_TRIES="${DOWNLOAD_TRIES:-3}"
DOWNLOAD_WAIT_RETRY="${DOWNLOAD_WAIT_RETRY:-10}"
DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-20}"
DOWNLOAD_READ_TIMEOUT="${DOWNLOAD_READ_TIMEOUT:-60}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-90}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_SPEEDTEST="${INSTALL_SPEEDTEST:-true}"
ENABLE_BBR="${ENABLE_BBR:-true}"
APPLY_UPDATES="${APPLY_UPDATES:-true}"
REMOVE_SNAPD="${REMOVE_SNAPD:-true}"
CLEAN_DOCS="${CLEAN_DOCS:-true}"
CONFIGURE_FASTFETCH="${CONFIGURE_FASTFETCH:-true}"

export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

require_bool() {
  local name="$1"
  local value="$2"

  case "${value}" in
    true|false) ;;
    *)
      echo "${name} 必须是 true 或 false，当前值：${value}" >&2
      exit 1
      ;;
  esac
}

require_positive_int() {
  local name="$1"
  local value="$2"

  case "${value}" in
    ''|*[!0-9]*|0)
      echo "${name} 必须是正整数，当前值：${value}" >&2
      exit 1
      ;;
  esac
}

require_bool INSTALL_HOST_TOOLS "${INSTALL_HOST_TOOLS}"
require_bool DOWNLOAD_ONLY "${DOWNLOAD_ONLY}"
require_bool INSTALL_DOCKER "${INSTALL_DOCKER}"
require_bool INSTALL_SPEEDTEST "${INSTALL_SPEEDTEST}"
require_bool ENABLE_BBR "${ENABLE_BBR}"
require_bool APPLY_UPDATES "${APPLY_UPDATES}"
require_bool REMOVE_SNAPD "${REMOVE_SNAPD}"
require_bool CLEAN_DOCS "${CLEAN_DOCS}"
require_bool CONFIGURE_FASTFETCH "${CONFIGURE_FASTFETCH}"
require_positive_int DOWNLOAD_TRIES "${DOWNLOAD_TRIES}"
require_positive_int DOWNLOAD_WAIT_RETRY "${DOWNLOAD_WAIT_RETRY}"
require_positive_int DOWNLOAD_CONNECT_TIMEOUT "${DOWNLOAD_CONNECT_TIMEOUT}"
require_positive_int DOWNLOAD_READ_TIMEOUT "${DOWNLOAD_READ_TIMEOUT}"
require_positive_int DOWNLOAD_TIMEOUT "${DOWNLOAD_TIMEOUT}"

case "${IMAGE_PROFILE}" in
  minimal|common) ;;
  *)
    echo "不支持的 IMAGE_PROFILE：${IMAGE_PROFILE}" >&2
    echo "可选值：minimal common" >&2
    exit 1
    ;;
esac

case "${IMAGE_ID}" in
  debian12)
    OS_FAMILY="debian"
    OS_RELEASE="12"
    IMAGE_NAME="debian-12-genericcloud-amd64-pve-${IMAGE_PROFILE}"
    IMAGE_URLS=(
      "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      "https://mirror.sjtu.edu.cn/debian-cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    )
    DOCKER_OS="debian"
    ;;
  debian13)
    OS_FAMILY="debian"
    OS_RELEASE="13"
    IMAGE_NAME="debian-13-genericcloud-amd64-pve-${IMAGE_PROFILE}"
    IMAGE_URLS=(
      "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
      "https://mirror.sjtu.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    )
    DOCKER_OS="debian"
    ;;
  ubuntu2204)
    OS_FAMILY="ubuntu"
    OS_RELEASE="22.04"
    IMAGE_NAME="ubuntu-22.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}"
    IMAGE_URLS=(
      "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
      "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/jammy/current/jammy-server-cloudimg-amd64.img"
      "https://mirror.sjtu.edu.cn/ubuntu-cloud-images/jammy/current/jammy-server-cloudimg-amd64.img"
    )
    DOCKER_OS="ubuntu"
    ;;
  ubuntu2404)
    OS_FAMILY="ubuntu"
    OS_RELEASE="24.04"
    IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}"
    IMAGE_URLS=(
      "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64.img"
      "https://mirror.sjtu.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64.img"
    )
    DOCKER_OS="ubuntu"
    ;;
  ubuntu2604)
    OS_FAMILY="ubuntu"
    OS_RELEASE="26.04"
    IMAGE_NAME="ubuntu-26.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}"
    IMAGE_URLS=(
      "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
      "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/resolute/current/resolute-server-cloudimg-amd64.img"
      "https://mirror.sjtu.edu.cn/ubuntu-cloud-images/resolute/current/resolute-server-cloudimg-amd64.img"
    )
    DOCKER_OS="ubuntu"
    ;;
  *)
    echo "不支持的 IMAGE_ID：${IMAGE_ID}" >&2
    echo "可选值：debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604" >&2
    exit 1
    ;;
esac

IMAGE_URL="${IMAGE_URLS[0]}"

if [ -z "${IMAGE_DISK_SIZE}" ]; then
  case "${IMAGE_ID}" in
    ubuntu2604) IMAGE_DISK_SIZE="6G" ;;
    *) IMAGE_DISK_SIZE="4G" ;;
  esac
fi

SRC_IMAGE="${SRC_IMAGE:-${WORKDIR}/${IMAGE_NAME}-src.qcow2}"
WORK_IMAGE="${WORKDIR}/${IMAGE_NAME}-work.qcow2"
FINAL_IMAGE="${FINAL_IMAGE:-${WORKDIR}/${IMAGE_NAME}.qcow2}"

MINIMAL_PACKAGES="sudo,openssh-server,cloud-init,qemu-guest-agent,cloud-guest-utils,e2fsprogs,ca-certificates,curl,wget,unzip,less,nano,iproute2,iputils-ping"
COMMON_PACKAGES="btop,chrony,git,vim,jq,rsync,dnsutils,mtr-tiny,traceroute,tcpdump,lsof,socat,zip,zstd,bash-completion"

if [ "${IMAGE_PROFILE}" = "common" ]; then
  EFFECTIVE_INSTALL_DOCKER="${INSTALL_DOCKER}"
  EFFECTIVE_INSTALL_SPEEDTEST="${INSTALL_SPEEDTEST}"
  EFFECTIVE_ENABLE_BBR="${ENABLE_BBR}"
else
  EFFECTIVE_INSTALL_DOCKER="false"
  EFFECTIVE_INSTALL_SPEEDTEST="false"
  EFFECTIVE_ENABLE_BBR="false"
fi

echo "============================================================"
echo "开始定制 PVE Cloud Image"
echo "镜像 ID：${IMAGE_ID}"
echo "镜像档位：${IMAGE_PROFILE}"
echo "镜像地址：${IMAGE_URL}"
echo "源镜像：${SRC_IMAGE}"
echo "工作目录：${WORKDIR}"
if [ "${DOWNLOAD_ONLY}" = "false" ]; then
  echo "最终镜像：${FINAL_IMAGE}"
fi
echo "系统：${OS_FAMILY} ${OS_RELEASE}"
echo "时区：${TIMEZONE}"
echo "虚拟磁盘：${IMAGE_DISK_SIZE}"
echo "根分区：${ROOT_PARTITION}"
echo "下载重试：每个源 ${DOWNLOAD_TRIES} 次，失败后切换下一个源"
echo "备用镜像源："
printf '  - %s\n' "${IMAGE_URLS[@]}"
echo "保留 cloud kernel：true"
echo "安装 Docker：${EFFECTIVE_INSTALL_DOCKER} (请求值：${INSTALL_DOCKER})"
echo "安装 Speedtest CLI：${EFFECTIVE_INSTALL_SPEEDTEST} (请求值：${INSTALL_SPEEDTEST})"
echo "启用 TCP 窗口调优 / BBR：${EFFECTIVE_ENABLE_BBR} (请求值：${ENABLE_BBR})"
echo "应用系统更新：${APPLY_UPDATES}"
echo "仅下载源镜像：${DOWNLOAD_ONLY}"
echo "安装宿主工具：${INSTALL_HOST_TOOLS}"
echo "移除 snapd：${REMOVE_SNAPD}"
echo "清理文档缓存：${CLEAN_DOCS}"
echo "配置 fastfetch：${CONFIGURE_FASTFETCH}"
echo "libguestfs 后端：${LIBGUESTFS_BACKEND}"
echo "============================================================"

if [ "${INSTALL_HOST_TOOLS}" = "true" ]; then
  echo "[1/8] 安装宿主机构建工具..."
  sudo apt-get update
  if [ "${DOWNLOAD_ONLY}" = "true" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      wget \
      ca-certificates
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      libguestfs-tools \
      qemu-utils \
      wget \
      curl \
      ca-certificates
  fi
else
  echo "[1/8] 跳过宿主机构建工具安装..."
fi

echo "[2/8] 创建工作目录..."
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

download_cloud_image() {
  local dest="$1"
  local tmp="${dest}.part"
  shift

  mkdir -p "$(dirname "${dest}")"

  for url in "$@"; do
    rm -f "${tmp}"
    echo "尝试下载：${url}"
    if wget \
      --tries="${DOWNLOAD_TRIES}" \
      --waitretry="${DOWNLOAD_WAIT_RETRY}" \
      --random-wait \
      --connect-timeout="${DOWNLOAD_CONNECT_TIMEOUT}" \
      --read-timeout="${DOWNLOAD_READ_TIMEOUT}" \
      --timeout="${DOWNLOAD_TIMEOUT}" \
      --retry-connrefused \
      --max-redirect=5 \
      --progress=dot:giga \
      -O "${tmp}" \
      "${url}"; then
      mv -f "${tmp}" "${dest}"
      return 0
    fi

    rm -f "${tmp}"
    echo "镜像源下载失败，切换下一个源：${url}" >&2
  done

  echo "所有镜像源下载失败" >&2
  return 1
}

echo "[3/8] 下载 Cloud Image..."
if [ ! -f "${SRC_IMAGE}" ]; then
  download_cloud_image "${SRC_IMAGE}" "${IMAGE_URLS[@]}"
else
  echo "原始镜像已存在，跳过下载：${SRC_IMAGE}"
fi

if [ "${DOWNLOAD_ONLY}" = "true" ]; then
  echo "源镜像下载完成：${SRC_IMAGE}"
  exit 0
fi

echo "复制并扩大工作镜像虚拟磁盘..."
rm -f "${WORK_IMAGE}"
cp -f "${SRC_IMAGE}" "${WORK_IMAGE}"
qemu-img resize "${WORK_IMAGE}" "${IMAGE_DISK_SIZE}"

echo "源镜像分区信息："
sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-filesystems \
  --long \
  --parts \
  --blkdevs \
  -a "${WORK_IMAGE}"

echo "[4/8] 开始定制镜像..."

COMMON_INSTALL_ARGS=()
if [ "${IMAGE_PROFILE}" = "common" ]; then
  COMMON_INSTALL_ARGS+=(--install "${COMMON_PACKAGES}")
fi

DOCKER_INSTALL_ARGS=()
if [ "${EFFECTIVE_INSTALL_DOCKER}" = "true" ]; then
  DOCKER_INSTALL_ARGS+=(
    --run-command "install -m 0755 -d /etc/apt/keyrings"
    --run-command "curl -fsSL https://download.docker.com/linux/${DOCKER_OS}/gpg -o /etc/apt/keyrings/docker.asc"
    --run-command "chmod a+r /etc/apt/keyrings/docker.asc"
    --run-command "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list"
    --run-command "apt-get update"
    --run-command "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  )
fi

SPEEDTEST_INSTALL_ARGS=()
if [ "${EFFECTIVE_INSTALL_SPEEDTEST}" = "true" ] && [ "${IMAGE_ID}" = "debian13" ]; then
  SPEEDTEST_INSTALL_ARGS+=(
    --run-command "install -m 0755 -d /etc/apt/keyrings"
    --run-command "curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey -o /etc/apt/keyrings/ookla-speedtest.asc"
    --run-command "chmod a+r /etc/apt/keyrings/ookla-speedtest.asc"
    --run-command ". /etc/os-release && echo \"deb [signed-by=/etc/apt/keyrings/ookla-speedtest.asc] https://packagecloud.io/ookla/speedtest-cli/\${ID}/ \${VERSION_CODENAME} main\" > /etc/apt/sources.list.d/ookla-speedtest.list"
    --run-command "apt-get update"
    --run-command "DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest"
  )
elif [ "${EFFECTIVE_INSTALL_SPEEDTEST}" = "true" ]; then
  echo "Speedtest CLI 目前只在 debian13 镜像中安装，其它 IMAGE_ID 跳过。"
fi

BBR_ARGS=()
if [ "${EFFECTIVE_ENABLE_BBR}" = "true" ]; then
  BBR_ARGS+=(
    --write "/etc/sysctl.d/99-pve-tcp-tune.conf:# PVE common profile TCP tuning
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
"
  )
fi

FASTFETCH_ARGS=()
if [ "${IMAGE_PROFILE}" = "common" ] && [ "${CONFIGURE_FASTFETCH}" = "true" ]; then
  FASTFETCH_ARGS+=(
    --run-command "if apt-cache show fastfetch >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y fastfetch; fi"
    --run-command "mkdir -p /root/.config/fastfetch"
    --write "/root/.config/fastfetch/config.jsonc:{
  \"\$schema\": \"https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json\",
  \"logo\": {
    \"type\": \"auto\"
  },
  \"display\": {
    \"separator\": \" : \"
  },
  \"modules\": [
    \"title\",
    \"separator\",
    \"os\",
    \"host\",
    \"kernel\",
    \"uptime\",
    \"packages\",
    \"shell\",
    \"cpu\",
    \"memory\",
    \"disk\",
    \"localip\",
    \"break\"
  ]
}
"
  )
fi

sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-customize -a "${WORK_IMAGE}" \
  --memsize 2048 \
  --smp 2 \
  --timezone "${TIMEZONE}" \
  \
  --write "/etc/apt/apt.conf.d/99-pve-template-no-recommends:APT::Install-Recommends \"false\";
APT::Install-Suggests \"false\";
" \
  \
  --run-command "apt-get update" \
  --install "cloud-guest-utils,e2fsprogs" \
  --run-command "growpart /dev/sda 1 || true" \
  --run-command "resize2fs '${ROOT_PARTITION}' || true" \
  --run-command "df -h /" \
  --run-command "if [ '${APPLY_UPDATES}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade; fi" \
  --install "${MINIMAL_PACKAGES}" \
  "${COMMON_INSTALL_ARGS[@]}" \
  \
  --append-line "/etc/default/grub:GRUB_DISABLE_OS_PROBER=true" \
  --write "/etc/default/grub.d/99-pve-cloud-init.cfg:# PVE NoCloud network config expects eth0 on some guests.
GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX} net.ifnames=0 biosdevname=0\"
" \
  --run-command "update-grub || true" \
  \
  --run-command "sed -i 's|Types: deb deb-src|Types: deb|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true" \
  --run-command "sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' /etc/cloud/cloud.cfg.d/01_debian_cloud.cfg 2>/dev/null || true" \
  --write "/etc/cloud/cloud.cfg.d/99-pve-template.cfg:disable_root: false
ssh_pwauth: true
package_update: false
package_upgrade: false
package_reboot_if_required: false
chpasswd:
  expire: false
" \
  \
  --run-command "test -f /etc/ssh/sshd_config || touch /etc/ssh/sshd_config" \
  --run-command "sed -i -E '/^[[:space:]]*#?[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|UsePAM)[[:space:]]/d' /etc/ssh/sshd_config" \
  --run-command "tmp=\"\$(mktemp)\"; { printf '%s\n' '# PVE cloud-init root login policy' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication yes' 'PubkeyAuthentication yes' 'UsePAM yes' ''; cat /etc/ssh/sshd_config; } > \"\${tmp}\"; cat \"\${tmp}\" > /etc/ssh/sshd_config; rm -f \"\${tmp}\"" \
  \
  "${BBR_ARGS[@]}" \
  "${DOCKER_INSTALL_ARGS[@]}" \
  "${SPEEDTEST_INSTALL_ARGS[@]}" \
  "${FASTFETCH_ARGS[@]}" \
  \
  --run-command "if [ '${REMOVE_SNAPD}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge snapd packagekit packagekit-tools || true; rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd; fi" \
  --run-command "if [ '${EFFECTIVE_INSTALL_DOCKER}' = 'true' ]; then systemctl enable docker || true; fi" \
  --run-command "systemctl enable ssh || systemctl enable sshd || true" \
  --run-command "systemctl enable qemu-guest-agent || true" \
  --run-command "systemctl enable serial-getty@ttyS0.service || true" \
  --run-command "systemctl enable serial-getty@ttyS1.service || true" \
  --run-command "mkdir -p /root/.ssh && chmod 700 /root/.ssh" \
  --run-command "apt-get -y autoremove --purge || true" \
  --run-command "apt-get -y clean || true" \
  --run-command "if [ '${CLEAN_DOCS}' = 'true' ]; then rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*; fi" \
  --run-command "cloud-init clean --logs || true; rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance; rm -f /etc/netplan/50-cloud-init.yaml; rm -rf /tmp/* /var/tmp/*" \
  --delete "/var/log/*.log" \
  --delete "/var/lib/apt/lists/*" \
  --delete "/var/cache/apt/*" \
  --truncate "/etc/machine-id"

echo "[5/8] 检查镜像信息..."
qemu-img info "${WORK_IMAGE}"

echo "[6/8] 压缩镜像..."
rm -f "${FINAL_IMAGE}"
sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-sparsify --compress "${WORK_IMAGE}" "${FINAL_IMAGE}"
sudo chown "$(id -u):$(id -g)" "${FINAL_IMAGE}"

echo "[7/8] 最终镜像信息..."
qemu-img info "${FINAL_IMAGE}"

echo "[8/8] 生成 SHA256 校验文件..."
(
  cd "$(dirname "${FINAL_IMAGE}")"
  sha256sum "$(basename "${FINAL_IMAGE}")" | tee "$(basename "${FINAL_IMAGE}").sha256"
)

echo "完成"
echo "============================================================"
echo "PVE Cloud Image 定制完成"
echo "镜像 ID：${IMAGE_ID}"
echo "镜像档位：${IMAGE_PROFILE}"
echo "最终镜像路径：${FINAL_IMAGE}"
echo "默认 root 密码：未设置，使用 PVE cloud-init 注入"
echo "SSH 策略：允许 root 密钥登录和 root 密码登录，凭据由 PVE cloud-init 注入"
echo "Docker：${EFFECTIVE_INSTALL_DOCKER}"
echo "Speedtest CLI：${EFFECTIVE_INSTALL_SPEEDTEST}"
echo "TCP 窗口调优 / BBR：${EFFECTIVE_ENABLE_BBR}"
echo "SHA256：${FINAL_IMAGE}.sha256"
echo "============================================================"
