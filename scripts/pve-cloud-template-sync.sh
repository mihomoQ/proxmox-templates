#!/bin/sh
set -eu

REPO="${REPO:-mihomoQ/proxmox-templates}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
IMAGE_ID="${IMAGE_ID:-debian13}"
IMAGE_PROFILE="${IMAGE_PROFILE:-minimal}"
VMID="${VMID:-9013}"
NAME="${NAME:-}"
STORAGE="${STORAGE:-}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-1024}"
CORES="${CORES:-1}"
CIUSER="${CIUSER:-root}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/var/lib/vz/template/pve-cloud-images}"
STATE_DIR="${STATE_DIR:-/var/lib/pve-cloud-template-sync}"
REPLACE_EXISTING="${REPLACE_EXISTING:-false}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

case "${IMAGE_PROFILE}" in
  minimal|common) ;;
  *) die "IMAGE_PROFILE must be minimal or common" ;;
esac

case "${REPLACE_EXISTING}" in
  true|false) ;;
  *) die "REPLACE_EXISTING must be true or false" ;;
esac

case "${IMAGE_ID}" in
  debian12)
    IMAGE_FILE="debian-12-genericcloud-amd64-pve-${IMAGE_PROFILE}.qcow2"
    DEFAULT_NAME="debian-12-${IMAGE_PROFILE}-template"
    ;;
  debian13)
    IMAGE_FILE="debian-13-genericcloud-amd64-pve-${IMAGE_PROFILE}.qcow2"
    DEFAULT_NAME="debian-13-${IMAGE_PROFILE}-template"
    ;;
  ubuntu2204)
    IMAGE_FILE="ubuntu-22.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}.qcow2"
    DEFAULT_NAME="ubuntu-22.04-${IMAGE_PROFILE}-template"
    ;;
  ubuntu2404)
    IMAGE_FILE="ubuntu-24.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}.qcow2"
    DEFAULT_NAME="ubuntu-24.04-${IMAGE_PROFILE}-template"
    ;;
  ubuntu2604)
    IMAGE_FILE="ubuntu-26.04-server-cloudimg-amd64-pve-${IMAGE_PROFILE}.qcow2"
    DEFAULT_NAME="ubuntu-26.04-${IMAGE_PROFILE}-template"
    ;;
  *)
    die "unsupported IMAGE_ID: ${IMAGE_ID}"
    ;;
esac

[ -n "${NAME}" ] || NAME="${DEFAULT_NAME}"

need_cmd awk
need_cmd grep
need_cmd sed
need_cmd sha256sum
need_cmd qm
need_cmd pvesm

if command -v curl >/dev/null 2>&1; then
  FETCH="curl"
elif command -v wget >/dev/null 2>&1; then
  FETCH="wget"
else
  die "missing command: curl or wget"
fi

fetch_to_file() {
  url="$1"
  dest="$2"

  if [ "${FETCH}" = "curl" ]; then
    curl -fL --retry 5 --retry-delay 5 --connect-timeout 20 -o "${dest}" "${url}"
  else
    wget --tries=5 --waitretry=5 --connect-timeout=20 -O "${dest}" "${url}"
  fi
}

fetch_stdout() {
  url="$1"

  if [ "${FETCH}" = "curl" ]; then
    curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 20 "${url}"
  else
    wget -qO- --tries=5 --waitretry=5 --connect-timeout=20 "${url}"
  fi
}

resolve_release_tag() {
  if [ "${RELEASE_TAG}" != "latest" ]; then
    printf '%s\n' "${RELEASE_TAG}"
    return
  fi

  fetch_stdout "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n1
}

detect_storage() {
  if [ -n "${STORAGE}" ]; then
    printf '%s\n' "${STORAGE}"
    return
  fi

  if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
    printf '%s\n' "local-lvm"
    return
  fi

  detected="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  if [ -n "${detected}" ]; then
    printf '%s\n' "${detected}"
    return
  fi

  detected="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${detected}" ] || die "unable to detect PVE storage; set STORAGE manually"
  printf '%s\n' "${detected}"
}

vm_exists() {
  qm config "${VMID}" >/dev/null 2>&1
}

release_tag="$(resolve_release_tag)"
[ -n "${release_tag}" ] || die "unable to resolve latest release tag"

base_url="https://github.com/${REPO}/releases/download/${release_tag}"
storage="$(detect_storage)"
state_file="${STATE_DIR}/${VMID}-${IMAGE_ID}-${IMAGE_PROFILE}.state"

mkdir -p "${DOWNLOAD_DIR}" "${STATE_DIR}"
tmpdir="${DOWNLOAD_DIR}/.${IMAGE_FILE}.${release_tag}.$$"
rm -rf "${tmpdir}"
mkdir -p "${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

echo "Release: ${release_tag}"
echo "Image: ${IMAGE_FILE}"
echo "VMID: ${VMID}"
echo "Storage: ${storage}"

fetch_to_file "${base_url}/${IMAGE_FILE}.sha256" "${tmpdir}/${IMAGE_FILE}.sha256"
expected_sha="$(awk '{print $1; exit}' "${tmpdir}/${IMAGE_FILE}.sha256")"
[ -n "${expected_sha}" ] || die "empty sha256 file: ${IMAGE_FILE}.sha256"
new_state="${release_tag} ${expected_sha}"

if vm_exists && [ -f "${state_file}" ] && [ "$(cat "${state_file}")" = "${new_state}" ]; then
  echo "Template ${VMID} is already up to date."
  exit 0
fi

if vm_exists; then
  if [ "${REPLACE_EXISTING}" != "true" ]; then
    die "VMID ${VMID} already exists; set REPLACE_EXISTING=true to replace it"
  fi

  echo "Destroying existing VMID ${VMID} before import..."
  qm stop "${VMID}" --skiplock 1 >/dev/null 2>&1 || true
  qm destroy "${VMID}" --purge 1 --destroy-unreferenced-disks 1
fi

fetch_to_file "${base_url}/${IMAGE_FILE}" "${tmpdir}/${IMAGE_FILE}"
(
  cd "${tmpdir}"
  awk -v image="${IMAGE_FILE}" '{print $1 "  " image}' "${IMAGE_FILE}.sha256" | sha256sum -c -
)

mv -f "${tmpdir}/${IMAGE_FILE}" "${DOWNLOAD_DIR}/${IMAGE_FILE}"
mv -f "${tmpdir}/${IMAGE_FILE}.sha256" "${DOWNLOAD_DIR}/${IMAGE_FILE}.sha256"
image_path="${DOWNLOAD_DIR}/${IMAGE_FILE}"

qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${storage}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${BRIDGE}" \
  --agent 1 \
  --ostype l26 \
  --memory "${MEMORY}" \
  --cores "${CORES}"

qm importdisk "${VMID}" "${image_path}" "${storage}"
imported_disk="$(qm config "${VMID}" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}')"
[ -n "${imported_disk}" ] || die "unable to find imported unused disk"

qm set "${VMID}" --scsi0 "${imported_disk},discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ciuser "${CIUSER}"
qm set "${VMID}" --ipconfig0 "${IPCONFIG0}"
qm template "${VMID}"

printf '%s\n' "${new_state}" > "${state_file}"
echo "Template ${VMID} updated to ${release_tag}."
