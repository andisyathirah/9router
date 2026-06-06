# Deploy 9Router + Hermes Agent di VPS

Panduan deploy stack lengkap untuk:

- **9Router** — AI router/proxy yang routing request ke 40+ provider (Claude, Kiro, GLM, OpenAI, dll). Jalan sebagai service di VPS Anda. Source: [decolua/9router](https://github.com/decolua/9router).
- **Hermes Agent** — autonomous AI agent dari [Nous Research](https://github.com/NousResearch/hermes-agent) yang konek ke 9Router. Bisa di-install di VPS yang sama atau di laptop/server lain.

Target VPS: **4 vCPU / 8 GiB RAM / 100 GiB SSD** (misal Alibaba Cloud ESSD Entry, Vultr, Hetzner, DigitalOcean — semua oke).

---

## Isi folder `deploy/`

| File | Fungsi |
|---|---|
| `install-vps.sh` | Bootstrap VPS **Ubuntu/Debian**: Docker + UFW + swap + jalankan 9Router |
| `install-vps-centos.sh` | Bootstrap VPS **CentOS-family** (CentOS Stream / AlmaLinux / Rocky / RHEL 8+9): Docker + firewalld + EPEL + SELinux tweaks |
| `install-hermes.sh` | Install Hermes Agent + auto-config ke 9Router |
| `docker-compose.yml` | Stack 9Router + Caddy (auto HTTPS) |
| `Caddyfile` | Reverse proxy + TLS Let's Encrypt |
| `.env.production.example` | Template environment (jangan commit yang sudah berisi secret) |

---

## Arsitektur

```
                     Internet
                        |
                        v
        +--------------------------------+
        |  VPS  (4 vCPU / 8 GB / 100 GB) |
        |                                |
        |   +----------+    +---------+  |
        |   |  Caddy   |--->| 9Router |  |
        |   | :80 :443 |    |  :20128 |  |
        |   +----------+    +----+----+  |
        |                        |       |
        +------------------------+-------+
                                 |
                                 v
              +------------------------------+
              | Provider AI (Kiro / GLM /    |
              | Claude / OpenAI / dll)       |
              +------------------------------+

   [Hermes Agent CLI di laptop/VPS lain] ---> VPS:443/v1
```

---

## Bagian 1 — Deploy 9Router di VPS

### Prasyarat

- Salah satu dari (clean install):
  - **Ubuntu** 22.04 / 24.04, atau **Debian** 12 → pakai `install-vps.sh`
  - **CentOS Stream** 8 / 9, **AlmaLinux** 8 / 9, **Rocky Linux** 8 / 9, **RHEL** 8 / 9 → pakai `install-vps-centos.sh`
- Akses root via SSH
- (Opsional, sangat disarankan) Domain yang sudah pointing **A record** ke IP VPS untuk dapat HTTPS otomatis

### Langkah — Ubuntu / Debian

```bash
# 1. SSH ke VPS sebagai root
ssh root@IP-VPS-ANDA

# 2. Ambil folder deploy/ saja (tidak butuh seluruh source 9Router)
apt-get update && apt-get install -y git
git clone --depth 1 https://github.com/andisyathirah/9router.git
cd 9router/deploy

# 3a. Tanpa domain (HTTP only, akses via IP:20128)
sudo bash install-vps.sh

# 3b. Dengan domain (HTTPS otomatis via Let's Encrypt)
sudo DOMAIN=router.contohanda.com bash install-vps.sh
```

### Langkah — CentOS / AlmaLinux / Rocky / RHEL

```bash
# 1. SSH ke VPS sebagai root
ssh root@IP-VPS-ANDA

# 2. Install git lalu clone
dnf -y install git
git clone --depth 1 https://github.com/andisyathirah/9router.git
cd 9router/deploy

# 3a. Tanpa domain
sudo bash install-vps-centos.sh

# 3b. Dengan domain (HTTPS otomatis)
sudo DOMAIN=router.contohanda.com bash install-vps-centos.sh
```

> **Beda dari versi Ubuntu:** pakai `dnf` (bukan `apt`), `firewalld` (bukan `ufw`),
> tarik fail2ban dari **EPEL**, dan auto-set SELinux boolean
> `container_manage_cgroup` supaya container Docker tidak ditolak SELinux.
> Stack default pakai *named volume* (bukan bind-mount), jadi tidak perlu
> repot dengan label `:Z` SELinux.

Script akan:

1. Update apt + install paket dasar (curl, git, ufw, fail2ban, jq, openssl)
2. Bikin **swap 4 GB** (jaga-jaga RAM spike)
3. Install **Docker Engine** + **Compose plugin** dari repo resmi
4. Setup **UFW firewall** (allow 22, 80, 443)
5. Aktifkan **fail2ban** untuk proteksi SSH
6. Generate `.env.production` dengan secret random (`JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT`, password admin)
7. `docker compose up -d` — pull image `decolua/9router:latest` dan start

Selesai biasanya 3-5 menit. Output terakhir kasih:

```
==================================================================
 9Router siap!
==================================================================
  Dashboard : https://router.contohanda.com/dashboard
  API v1    : https://router.contohanda.com/v1

  Credentials disimpan di:
    /opt/9router/.initial-credentials.txt
==================================================================
```

### Setup awal di Dashboard

1. Buka URL dashboard, login pakai `admin` + password dari `.initial-credentials.txt`
2. Ganti password (wajib)
3. **Providers > Connect**: pilih provider AI:
   - **Kiro AI** (gratis, Claude 4.5 unlimited) — login via AWS Builder ID / Google / GitHub
   - **OpenCode Free** (gratis, no auth) — sekali klik
   - **GLM** ($0.6/1M tokens) — paste API key dari [Zhipu AI](https://open.bigmodel.cn/)
   - **Claude Code** (kalau punya subscription Pro/Max) — OAuth login
4. **API Keys > Create**: bikin API key untuk Hermes (catat keynya, dipakai di Bagian 2)
5. (Opsional) **Combos > Create**: bikin fallback chain Subscription -> Cheap -> Free

### Operasional

```bash
cd /opt/9router

docker compose logs -f 9router        # cek log realtime
docker compose restart                # restart
docker compose pull && docker compose up -d   # update ke versi terbaru
docker compose down                   # stop semua
```

Backup data:

```bash
# Database SQLite ada di volume Docker
docker run --rm -v 9router-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/9router-backup-$(date +%F).tar.gz /data
```

---

## Bagian 2 — Install Hermes Agent

Hermes Agent **tidak harus** di VPS yang sama dengan 9Router. Bisa di:

- VPS yang sama (kalau mau autonomous agent jalan 24/7 di server)
- Laptop / WSL2 (Windows native tidak didukung Hermes)
- Server lain mana saja

### Cara

```bash
# Copy install-hermes.sh ke mesin target, lalu:
bash install-hermes.sh \
  --endpoint https://router.contohanda.com/v1 \
  --api-key  sk_xxxxxxxxxxxxxxxx \
  --model    kr/claude-sonnet-4.5
```

Atau interaktif (akan ditanya satu-satu):

```bash
bash install-hermes.sh
```

Script akan:

1. Jalankan installer resmi Nous Research (`curl install.sh | bash`) — install `uv` + Python 3.11 + clone repo Hermes
2. Tulis `~/.hermes/config.yaml`:
   ```yaml
   model:
     default: "kr/claude-sonnet-4.5"
     provider: "custom"
     base_url: "https://router.contohanda.com/v1"
   ```
3. Tulis `~/.hermes/.env`:
   ```
   OPENAI_API_KEY=sk_xxxxxxxxxxxxxxxx
   ```
4. Verify koneksi via `GET /v1/models`

### Test Hermes

```bash
hermes chat "Halo, kamu siapa?"
```

### Pilihan Model (via 9Router)

| Provider | Model ID | Catatan |
|---|---|---|
| Kiro (gratis) | `kr/claude-sonnet-4.5` | Claude 4.5, unlimited gratis |
| Kiro (gratis) | `kr/glm-5` | GLM-5, unlimited gratis |
| Kiro (gratis) | `kr/MiniMax-M2.5` | MiniMax, unlimited gratis |
| OpenCode Free | `oc/<auto>` | No-auth passthrough |
| GLM (murah) | `glm/glm-5.1` | $0.6 / 1M tokens |
| Claude (subs) | `cc/claude-opus-4-7` | Butuh Claude Code subscription |

Ganti model nanti tanpa install ulang:

```bash
bash install-hermes.sh --model kr/glm-5 --skip-install
```

### Jalan Hermes 24/7 di VPS (systemd)

Kalau Hermes di-install di VPS dan mau jalan terus (misal dipakai jadi gateway WhatsApp/Telegram bot), bikin systemd unit:

```bash
sudo tee /etc/systemd/system/hermes.service >/dev/null <<'EOF'
[Unit]
Description=Hermes Agent
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu
ExecStart=/home/ubuntu/.local/bin/hermes serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes
sudo journalctl -u hermes -f
```

> Sesuaikan `User=` dan path `hermes` (cek dengan `which hermes`).

---

## Sizing untuk VPS 4 vCPU / 8 GB

Stack ini ringan. Estimasi pemakaian:

| Komponen | RAM idle | RAM peak | CPU |
|---|---|---|---|
| 9Router (Next.js) | 250-400 MB | 1-1.5 GB | < 1 vCPU |
| Caddy | 20 MB | 50 MB | minimal |
| Hermes Agent (kalau co-located) | 200 MB | 1-2 GB | spike saat agent loop |
| Sisanya buat OS + buffer | ~500 MB | — | — |

**Total**: ~1 GB idle, peak 3-4 GB saat heavy. VPS 8 GB sangat cukup, masih sisa banyak buat skill execution / build / test yang Hermes lakukan.

Disk 100 GB juga lebih dari cukup — 9Router DB biasanya < 500 MB setelah berbulan-bulan, Hermes repo + Python venv ~2 GB.

---

## Troubleshooting

**Caddy gagal dapat sertifikat HTTPS**
- Pastikan A record domain sudah pointing ke IP VPS (cek `dig router.contohanda.com`)
- Pastikan port 80 + 443 terbuka di firewall cloud provider (Alibaba security group, dll)
- Cek log: `docker compose logs caddy`

**(CentOS) `docker compose up` ditolak oleh SELinux**
- `getenforce` — kalau `Enforcing`, jalankan: `sudo setsebool -P container_manage_cgroup on`
- `sudo ausearch -m AVC -ts recent` — lihat denial terakhir
- Workaround terakhir (kurang aman): `sudo setenforce 0` (sementara) lalu cek apakah masalah
  benar dari SELinux

**(CentOS) firewalld tidak aktif / port tetap ketutup**
- `sudo systemctl status firewalld`
- `sudo firewall-cmd --list-all` — pastikan service `http`, `https`, dan port `20128/tcp`
  (kalau no-domain) ada di zone `public`
- Reload: `sudo firewall-cmd --reload`

**(CentOS RHEL) `epel-release` tidak ditemukan**
- RHEL official tidak punya EPEL di subscription default. Script akan fallback ke
  `https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm`. Kalau tetap
  gagal, fail2ban akan di-skip — tidak fatal, instalasi lanjut tanpa fail2ban.

**Dashboard 9Router tidak bisa diakses**
- `docker compose ps` — pastikan container `9router` status `healthy`
- `docker compose logs 9router | tail -50`
- Kalau pakai IP langsung (no domain): cek `ufw status` allow 20128, dan security group cloud provider juga allow 20128

**Hermes error "OpenAI API error 401"**
- API key di `~/.hermes/.env` salah / sudah dihapus dari dashboard
- Regenerate key di Dashboard > API Keys, lalu:
  ```bash
  sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=sk_keybaru|" ~/.hermes/.env
  ```

**Hermes error "Provider not found / model not found"**
- Pastikan provider yang dipilih sudah Connected di Dashboard 9Router
- Model ID format: `<prefix>/<model>` — contoh `kr/claude-sonnet-4.5`, bukan cuma `claude-sonnet-4.5`

**`hermes` command not found setelah install**
- Buka shell baru, atau:
  ```bash
  export PATH="$HOME/.local/bin:$PATH"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
  ```

---

## Update & Maintenance

```bash
# Update 9Router
cd /opt/9router
docker compose pull
docker compose up -d

# Update Hermes Agent
hermes update    # kalau ada subcommand-nya
# atau install ulang:
bash install-hermes.sh --skip-install   # cuma re-config

# Lihat resource usage
docker stats
```

---

## Keamanan — checklist sebelum production

- [ ] Ganti `INITIAL_PASSWORD` setelah login pertama
- [ ] Hapus `/opt/9router/.initial-credentials.txt` setelah dicatat
- [ ] Set `REQUIRE_API_KEY=true` di `.env.production` (lalu `docker compose up -d`)
- [ ] Pastikan `.env.production` permission **600** (`chmod 600`)
- [ ] Pakai HTTPS (set `DOMAIN=...`), jangan HTTP-only di production
- [ ] Batasi SSH: pakai key auth + disable password auth (`PasswordAuthentication no` di `/etc/ssh/sshd_config`)
- [ ] Backup volume `9router-data` rutin
- [ ] Monitor: `docker stats` + alert kalau memory > 80%
