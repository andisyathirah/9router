#!/usr/bin/env bash
# ============================================================
#  9Router VPS bootstrap — CentOS-family
#  Tested-target: CentOS Stream 9, AlmaLinux 9, Rocky Linux 9,
#                 RHEL 9 (juga jalan di Stream 8 / Alma 8 / Rocky 8)
#  Target VPS: 4 vCPU / 8 GB RAM / 100 GB disk (mis. Alibaba ESSD Entry)
# ------------------------------------------------------------
#  Yang di-setup script ini:
#    1. dnf update + paket dasar + EPEL (untuk fail2ban)
#    2. Swap 4 GB
#    3. Docker Engine + Compose plugin (repo resmi docker-ce)
#    4. firewalld (allow ssh, http, https)
#    5. SELinux tweaks supaya container bisa baca/tulis volume
#    6. fail2ban (proteksi SSH)
#    7. Pull image 9router & start lewat docker compose
#    8. Print URL akses + password awal
#
#  Pakainya:
#    sudo bash install-vps-centos.sh
#  Atau dengan domain:
#    sudo DOMAIN=router.contohanda.com bash install-vps-centos.sh
# ============================================================

set -euo pipefail

# --- Helper -----------------------------------------------------------------
log()  { printf "\e[1;32m[+] %s\e[0m\n" "$*"; }
warn() { printf "\e[1;33m[!] %s\e[0m\n" "$*"; }
err()  { printf "\e[1;31m[x] %s\e[0m\n" "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Jalankan script ini sebagai root (sudo bash install-vps-centos.sh)"
    exit 1
  fi
}

# --- Param ------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"                           # opsional, kosong = HTTP only
INSTALL_DIR="${INSTALL_DIR:-/opt/9router}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
SSH_PORT="${SSH_PORT:-22}"

require_root

# --- 0. Deteksi distro ------------------------------------------------------
if [[ ! -f /etc/os-release ]]; then
  err "/etc/os-release tidak ditemukan. Distro tidak didukung."
  exit 1
fi
. /etc/os-release

case "${ID,,}" in
  centos|rhel|almalinux|rocky)
    log "Distro: ${PRETTY_NAME}"
    ;;
  *)
    case "${ID_LIKE:-}" in
      *rhel*|*centos*|*fedora*) log "Distro RHEL-like: ${PRETTY_NAME}" ;;
      *) err "Script ini untuk CentOS-family. Detected: ${PRETTY_NAME}"
         err "Pakai install-vps.sh untuk Ubuntu/Debian."; exit 1 ;;
    esac
    ;;
esac

VERSION_MAJOR="${VERSION_ID%%.*}"

# Pilih package manager: dnf (RHEL 8+) — fallback yum kalau dnf gak ada.
if command -v dnf >/dev/null 2>&1; then
  PM=dnf
else
  PM=yum
fi

# --- 1. Update sistem + paket dasar -----------------------------------------
log "Update ${PM} & install paket dasar"
${PM} -y update
${PM} -y install \
  curl ca-certificates gnupg2 \
  firewalld jq openssl tar unzip htop policycoreutils-python-utils

# --- 1b. EPEL (untuk fail2ban) ----------------------------------------------
log "Install EPEL release (untuk fail2ban)"
if ! ${PM} -y install epel-release 2>/dev/null; then
  # RHEL official tidak punya epel-release di repo default
  warn "epel-release tidak ada di repo default — install via fedoraproject"
  ${PM} -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${VERSION_MAJOR}.noarch.rpm" || \
    warn "Gagal install EPEL. fail2ban akan di-skip."
fi

if ${PM} -y install fail2ban 2>/dev/null; then
  HAS_FAIL2BAN=1
else
  warn "fail2ban tidak terinstall (EPEL tidak tersedia). Skip."
  HAS_FAIL2BAN=0
fi

# --- 2. Swap ----------------------------------------------------------------
if [[ ! -f /swapfile ]] && [[ "${SWAP_SIZE_GB}" -gt 0 ]]; then
  log "Bikin swap ${SWAP_SIZE_GB} GB"
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  sysctl -w vm.swappiness=10 >/dev/null
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-9router-swappiness.conf
else
  log "Swap sudah ada / disabled, skip"
fi

# --- 3. Docker --------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Hapus podman/docker bawaan kalau ada (konflik dengan docker-ce)"
  ${PM} -y remove podman buildah runc 2>/dev/null || true
  ${PM} -y remove docker docker-client docker-client-latest \
                  docker-common docker-latest docker-latest-logrotate \
                  docker-logrotate docker-engine 2>/dev/null || true

  log "Tambah repo docker-ce resmi"
  ${PM} -y install dnf-plugins-core 2>/dev/null || ${PM} -y install yum-utils
  if command -v dnf >/dev/null 2>&1; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  else
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  fi

  log "Install Docker Engine + Compose plugin"
  ${PM} -y install docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
else
  log "Docker sudah terpasang ($(docker --version))"
fi

# --- 4. firewalld -----------------------------------------------------------
log "Setup firewalld (allow ${SSH_PORT}/tcp, http, https)"
systemctl enable --now firewalld

# Kalau SSH port custom, perlu bikin service definition baru.
if [[ "${SSH_PORT}" != "22" ]]; then
  firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
else
  firewall-cmd --permanent --add-service=ssh >/dev/null
fi
firewall-cmd --permanent --add-service=http  >/dev/null
firewall-cmd --permanent --add-service=https >/dev/null

# Kalau no-domain, expose juga port 20128 langsung.
if [[ -z "${DOMAIN}" ]]; then
  firewall-cmd --permanent --add-port=20128/tcp >/dev/null
fi

firewall-cmd --reload >/dev/null

# --- 5. SELinux tweaks ------------------------------------------------------
SELINUX_MODE="$(getenforce 2>/dev/null || echo Disabled)"
log "SELinux mode: ${SELINUX_MODE}"
if [[ "${SELINUX_MODE}" == "Enforcing" ]]; then
  # Boolean ini bikin container bisa manage cgroups (perlu untuk
  # beberapa workload Docker, gak masalah kalau set walau gak butuh).
  setsebool -P container_manage_cgroup on 2>/dev/null || true
  warn "SELinux dalam mode Enforcing — bind-mount host dir butuh label :Z"
  warn "Stack ini pakai named volume (9router-data, caddy-data) jadi aman."
fi

# --- 6. fail2ban ------------------------------------------------------------
if [[ "${HAS_FAIL2BAN}" == "1" ]]; then
  log "Aktifkan fail2ban (sshd jail)"
  # CentOS 9 minimal install kadang gak punya jail.local — bikin minimal.
  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
EOF
  fi
  systemctl enable --now fail2ban
fi

# --- 7. Deploy 9Router ------------------------------------------------------
log "Deploy 9Router ke ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in docker-compose.yml Caddyfile .env.production.example; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp -n "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
  fi
done

cd "${INSTALL_DIR}"

if [[ ! -f .env.production ]]; then
  log "Generate .env.production dengan secret random"
  JWT_SECRET="$(openssl rand -hex 48)"
  API_KEY_SECRET="$(openssl rand -hex 32)"
  MACHINE_ID_SALT="$(openssl rand -hex 32)"
  INITIAL_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  EFFECTIVE_DOMAIN="${DOMAIN:-:80}"
  PUBLIC_BASE_URL="http://$(curl -s ifconfig.me || echo localhost):20128"
  if [[ -n "${DOMAIN}" ]]; then
    PUBLIC_BASE_URL="https://${DOMAIN}"
  fi

  cat > .env.production <<EOF
# Auto-generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${INITIAL_PASSWORD}
DOMAIN=${EFFECTIVE_DOMAIN}

DATA_DIR=/app/data
PORT=20128
HOSTNAME=0.0.0.0
NODE_ENV=production

API_KEY_SECRET=${API_KEY_SECRET}
MACHINE_ID_SALT=${MACHINE_ID_SALT}

ENABLE_REQUEST_LOGS=false
OBSERVABILITY_ENABLED=true
AUTH_COOKIE_SECURE=$([ -n "${DOMAIN}" ] && echo true || echo false)
REQUIRE_API_KEY=false

BASE_URL=http://127.0.0.1:20128
CLOUD_URL=https://9router.com
NEXT_PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
NEXT_PUBLIC_CLOUD_URL=https://9router.com
EOF
  chmod 600 .env.production

  cat > .initial-credentials.txt <<EOF
================================================================
 9Router initial credentials — SIMPAN AMAN, lalu hapus file ini!
================================================================
 URL      : ${PUBLIC_BASE_URL}/dashboard
 Username : admin
 Password : ${INITIAL_PASSWORD}
================================================================
EOF
  chmod 600 .initial-credentials.txt
fi

if [[ -z "${DOMAIN}" ]]; then
  warn "DOMAIN tidak diset — 9Router akan diakses via http://<IP-VPS>:20128"
  warn "Disarankan beli domain + set DOMAIN=... biar dapat HTTPS otomatis."
  sed -i 's|"127.0.0.1:20128:20128"|"0.0.0.0:20128:20128"|' docker-compose.yml || true
fi

log "Pull image & start container"
docker compose pull
docker compose up -d

log "Tunggu container ready..."
sleep 8
docker compose ps

# --- 8. Output --------------------------------------------------------------
echo
echo "=================================================================="
echo " 9Router siap!"
echo "=================================================================="
if [[ -n "${DOMAIN}" ]]; then
  echo "  Dashboard : https://${DOMAIN}/dashboard"
  echo "  API v1    : https://${DOMAIN}/v1"
else
  PUBLIC_IP="$(curl -s ifconfig.me || echo "<IP-VPS>")"
  echo "  Dashboard : http://${PUBLIC_IP}:20128/dashboard"
  echo "  API v1    : http://${PUBLIC_IP}:20128/v1"
fi
echo
echo "  Credentials disimpan di:"
echo "    ${INSTALL_DIR}/.initial-credentials.txt"
echo
echo "  Cek log     : cd ${INSTALL_DIR} && docker compose logs -f 9router"
echo "  Restart     : cd ${INSTALL_DIR} && docker compose restart"
echo "  Update      : cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
echo "=================================================================="
