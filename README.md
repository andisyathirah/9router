# 9Router + Hermes Agent — VPS Deployment Pack

Paket deployment siap pakai untuk menjalankan [9Router](https://github.com/decolua/9router) (AI router/proxy) bersama [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research) di VPS.

Target: **4 vCPU / 8 GiB RAM / 100 GiB SSD** (Alibaba Cloud ESSD Entry, Vultr, Hetzner, DO, dll).

## Quick start

```bash
git clone --depth 1 https://github.com/andisyathirah/9router.git
cd 9router/deploy

# Deploy 9Router (HTTPS otomatis kalau punya domain)
# Ubuntu / Debian:
sudo DOMAIN=router.contohanda.com bash install-vps.sh
# CentOS Stream / AlmaLinux / Rocky / RHEL 8+9:
sudo DOMAIN=router.contohanda.com bash install-vps-centos.sh

# Install Hermes Agent + auto-config ke 9Router
bash install-hermes.sh \
  --endpoint https://router.contohanda.com/v1 \
  --api-key  sk_xxx \
  --model    kr/claude-sonnet-4.5
```

Detail lengkap, troubleshooting, dan tuning ada di [`deploy/README.md`](./deploy/README.md).

## Lisensi

Script di folder `deploy/` ini di-release di bawah lisensi yang sama dengan 9Router (MIT). 9Router dan Hermes Agent adalah proyek dari pihak ketiga; lihat repo masing-masing untuk lisensi mereka.
