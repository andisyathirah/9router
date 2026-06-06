#!/usr/bin/env bash
# ============================================================
#  Hermes Agent installer + auto-config ke 9Router
# ------------------------------------------------------------
#  Hermes Agent (Nous Research) butuh:
#    - Linux / macOS / WSL2 (Windows native TIDAK didukung)
#    - Python 3.11 (auto-install via uv)
#    - Internet ke github.com
#
#  Yang dikerjain script ini:
#    1. Install Hermes Agent (installer resmi Nous Research)
#    2. Tulis ~/.hermes/config.yaml → arahkan ke 9Router
#    3. Tulis ~/.hermes/.env       → OPENAI_API_KEY
#    4. Verify config + cetak cara pakai
#
#  Pakainya:
#    bash install-hermes.sh \
#      --endpoint https://router.contohanda.com/v1 \
#      --api-key  sk_xxxxxxxxxx \
#      --model    kr/claude-sonnet-4.5
#
#  Atau interaktif (akan ditanya kalau flag kosong):
#    bash install-hermes.sh
# ============================================================

set -euo pipefail

# --- Helper -----------------------------------------------------------------
log()  { printf "\e[1;32m[+] %s\e[0m\n" "$*"; }
warn() { printf "\e[1;33m[!] %s\e[0m\n" "$*"; }
err()  { printf "\e[1;31m[x] %s\e[0m\n" "$*" >&2; }

# --- Param ------------------------------------------------------------------
ENDPOINT=""
API_KEY=""
MODEL=""
SKIP_INSTALL="${SKIP_INSTALL:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--endpoint)  ENDPOINT="$2"; shift 2 ;;
    -k|--api-key)   API_KEY="$2";  shift 2 ;;
    -m|--model)     MODEL="$2";    shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
done

prompt_if_empty() {
  local var="$1" question="$2" default="${3:-}"
  if [[ -z "${!var}" ]]; then
    if [[ -n "${default}" ]]; then
      read -rp "${question} [${default}]: " val
      val="${val:-${default}}"
    else
      read -rp "${question}: " val
    fi
    printf -v "${var}" "%s" "${val}"
  fi
}

# --- 0. Sanity check -------------------------------------------------------
case "$(uname -s)" in
  Linux*|Darwin*) ;;
  *) err "Hermes Agent hanya support Linux/macOS/WSL2."; exit 1 ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
  warn "Disarankan jalanin script ini sebagai user biasa, bukan root."
  warn "Hermes akan di-install ke \$HOME (= /root) kalau tetap diteruskan."
fi

command -v curl >/dev/null || { err "curl tidak terpasang"; exit 1; }
command -v git  >/dev/null || { err "git tidak terpasang. Install: sudo apt install git"; exit 1; }

# --- 1. Install Hermes -----------------------------------------------------
if [[ "${SKIP_INSTALL}" != "1" ]]; then
  if command -v hermes >/dev/null 2>&1; then
    log "Hermes sudah terpasang ($(hermes --version 2>/dev/null || echo binary terdeteksi))"
  else
    log "Install Hermes Agent (Nous Research) — bisa makan 1-3 menit"
    # Installer resmi: provisions uv + Python 3.11 + clones repo, no sudo.
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

    # Installer biasanya nambah ke ~/.bashrc / ~/.zshrc — load ulang shell.
    # shellcheck disable=SC1091
    [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" || true
    [[ -f "$HOME/.profile" ]] && source "$HOME/.profile" || true

    if ! command -v hermes >/dev/null 2>&1; then
      warn "Binary 'hermes' belum di PATH. Coba buka shell baru, atau jalankan:"
      warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi
fi

# --- 2. Tanya endpoint / api key / model -----------------------------------
prompt_if_empty ENDPOINT "9Router endpoint URL (contoh: https://router.contohanda.com/v1)"
prompt_if_empty API_KEY  "9Router API key (dari Dashboard - API Keys)"
prompt_if_empty MODEL    "Model default Hermes" "kr/claude-sonnet-4.5"

# Normalize endpoint — pastikan ada /v1 di belakang.
if [[ "${ENDPOINT}" != */v1 ]] && [[ "${ENDPOINT}" != */v1/ ]]; then
  ENDPOINT="${ENDPOINT%/}/v1"
fi
ENDPOINT="${ENDPOINT%/}"

# --- 3. Tulis config -------------------------------------------------------
HERMES_DIR="$HOME/.hermes"
CONFIG_FILE="$HERMES_DIR/config.yaml"
ENV_FILE="$HERMES_DIR/.env"
mkdir -p "${HERMES_DIR}"

# Backup config lama kalau ada.
if [[ -f "${CONFIG_FILE}" ]]; then
  cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%s)"
  log "Backup config lama -> ${CONFIG_FILE}.bak.*"
fi

# Tulis ulang block model: (sisanya kalau ada di config lama, kita pertahankan).
if [[ -f "${CONFIG_FILE}" ]]; then
  # Hapus block model: lama (pola match: 'model:\n' + indented lines).
  awk '
    BEGIN { skip = 0 }
    /^model:[ \t]*$/ { skip = 1; next }
    skip == 1 {
      if ($0 ~ /^[ \t]/ || $0 ~ /^[ \t]*$/) next
      skip = 0
    }
    { print }
  ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
  mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
fi

{
  echo "model:"
  echo "  default: \"${MODEL}\""
  echo "  provider: \"custom\""
  echo "  base_url: \"${ENDPOINT}\""
  if [[ -f "${CONFIG_FILE}" ]] && [[ -s "${CONFIG_FILE}" ]]; then
    echo ""
    cat "${CONFIG_FILE}"
  fi
} > "${CONFIG_FILE}.new"
mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"

# Tulis OPENAI_API_KEY ke .env (Hermes baca dari sini).
touch "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
if grep -q '^OPENAI_API_KEY=' "${ENV_FILE}"; then
  sed -i.bak "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${API_KEY}|" "${ENV_FILE}"
else
  echo "OPENAI_API_KEY=${API_KEY}" >> "${ENV_FILE}"
fi

# --- 4. Verify -------------------------------------------------------------
log "Config tertulis di ${CONFIG_FILE}"
log "Env    tertulis di ${ENV_FILE}"
echo
log "Test koneksi ke 9Router..."
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  "${ENDPOINT}/models" || echo 000)"
case "${HTTP_CODE}" in
  200) log "9Router merespon OK (HTTP 200)" ;;
  401|403) warn "Endpoint nyala tapi API key ditolak (HTTP ${HTTP_CODE}). Cek API key di Dashboard." ;;
  000) warn "Tidak bisa connect ke ${ENDPOINT}. Cek DNS / firewall / domain." ;;
  *)   warn "9Router merespon dengan HTTP ${HTTP_CODE}" ;;
esac

# --- 5. Output -------------------------------------------------------------
echo
echo "=================================================================="
echo " Hermes Agent siap!"
echo "=================================================================="
echo "  Endpoint : ${ENDPOINT}"
echo "  Model    : ${MODEL}"
echo "  Config   : ${CONFIG_FILE}"
echo "  Env      : ${ENV_FILE}"
echo
echo "  Coba:"
echo "    hermes chat \"Halo, kamu siapa?\""
echo
echo "  Ganti model nanti:"
echo "    bash install-hermes.sh --model kr/glm-5 --skip-install"
echo "=================================================================="
