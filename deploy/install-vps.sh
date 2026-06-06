#!/usr/bin/env bash
# ============================================================
#  9Router VPS bootstrap — Ubuntu 22.04 / 24.04, Debian 12
#  Target VPS: 4 vCPU / 8 GB RAM / 100 GB disk (mis. Alibaba ESSD Entry)
# ------------------------------------------------------------
#  Yang di-setup script ini:
#    1. System update + paket dasar
#    2. Swap 4 GB (jaga-jaga kalau RAM spike pas build)
#    3. Docker Engine + Compose plugin (repo resmi)
#    4. UFW firewall (22, 80, 443)
#    5. fail2ban (proteksi SSH)
#    6. Pull image 9router & start lewat docker compose
#    7. Print URL akses + password awal
#
#  Pakainya:
#    sudo bash install-vps.sh
#  Atau dengan domain:
#    sudo DOMAIN=router.contohanda.com bash install-vps.sh
# ============================================================

set -euo pipefail

# --- Helper -----------------------------------------------------------------
log()  { printf "\e[1;32m[+] %s\e[0m\n" "$*"; }
warn() { printf "\e[1;33m[!] %s\e[0m\n" "$*"; }
err()  { printf "\e[1;31m[x] %s\e[0m\n" "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Jalankan script ini sebagai root (sudo bash install-vps.sh)"
    exit 1
  fi
}

# --- Param ------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"                           # opsional, kosong = HTTP only
INSTALL_DIR="${INSTALL_DIR:-/opt/9router}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-4}"
SSH_PORT="${SSH_PORT:-22}"

require_root

# --- 1. Update sistem -------------------------------------------------------
log "Update apt & install paket dasar"
export DEBIAN_FRONTEND=noninteractive
yum update -y
yum upgrade -y
yum install -y \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban htop unzip jq openssl \
  apt-transport-https software-properties-common

# --- 2. Swap ----------------------------------------------------------------
if [[ ! -f /swapfile ]] && [[ "${SWAP_SIZE_GB}" -gt 0 ]]; then
  log "Bikin swap ${SWAP_SIZE_GB} GB"
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
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
  log "Install Docker Engine + Compose plugin"
  install -m 0755 -d /etc/yum/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/yum/keyrings/docker.gpg
  chmod a+r /etc/yum/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(yum --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  yum update -y
  yum install -y docker-ce docker-ce-cli containerd.io \
                     docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker sudah terpasang ($(docker --version))"
fi

# --- 4. UFW -----------------------------------------------------------------
log "Setup UFW firewall (allow ${SSH_PORT}/tcp, 80, 443)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}"/tcp comment 'SSH'
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# --- 5. fail2ban ------------------------------------------------------------
log "Aktifkan fail2ban (sshd jail default)"
systemctl enable --now fail2ban

# --- 6. Deploy 9Router ------------------------------------------------------
log "Deploy 9Router ke ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Salin file deploy (compose, Caddyfile, env example) ke INSTALL_DIR.
for f in docker-compose.yml Caddyfile .env.production.example; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    cp -n "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
  fi
done

cd "${INSTALL_DIR}"

# Generate .env.production kalau belum ada.
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

# Kalau user belum set DOMAIN, modif compose biar Caddy jalan di :80 only
# dan port 9router di-publish langsung ke 0.0.0.0 (biar bisa diakses via IP).
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

# --- 7. Output --------------------------------------------------------------
echo
echo "=================================================================="
echo " ✅  9Router siap!"
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
