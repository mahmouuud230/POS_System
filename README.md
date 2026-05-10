# Odoo 18 Multi-Tenant POS SaaS — Deployment Guide

## Architecture Overview

```
Internet
    │
    ▼ :80/:443
┌──────────────────────────────┐
│  Nginx Proxy Manager (NPM)   │  TLS termination, wildcard Let's Encrypt
│  shop1.domain.com → odoo:8069│  Per-tenant proxy hosts
│  shop2.domain.com → odoo:8069│
└──────────────┬───────────────┘
               │ internal docker network (odoo-net)
               ▼
┌──────────────────────────────┐
│  Odoo 18 Community           │  Single instance, multi-database
│  db_filter = ^%d$            │  shop1.domain.com → DB "shop1"
│  list_db = False             │  shop2.domain.com → DB "shop2"
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  PostgreSQL 15               │  One database per tenant
│  DB: shop1, shop2, ...       │  Fully isolated
└──────────────────────────────┘
```

---

## Prerequisites

- Ubuntu 24.04 LTS VPS (minimum 2 vCPU, 4 GB RAM)
- Root or sudo SSH access
- A domain with DNS managed (e.g. Cloudflare)
- Wildcard DNS: `*.yourdomain.com` → VPS IP

---

## Step 1 — Server Hardening

```bash
# Upload harden_server.sh to the VPS and run:
sudo bash harden_server.sh
```

This script:
- Enforces SSH key-only authentication (disable password auth)
- Configures UFW: opens only ports 22, 80, 443
- Installs Fail2Ban with SSH + Odoo login jails
- Installs Docker CE + Compose plugin
- Creates `odoo-saas.service` (auto-start on boot)
- Creates `odoo-backup.timer` (daily backups at 02:00)

> **NPM Admin port 81** is intentionally NOT opened in UFW.
> Access it via SSH tunnel during initial setup:
> ```bash
> ssh -L 8081:localhost:81 ubuntu@<YOUR_VPS_IP>
> # Then open http://localhost:8081 in your browser
> ```

---

## Step 2 — Deploy the Stack

```bash
# Create the project directory
sudo mkdir -p /opt/odoo-saas
sudo chown ubuntu:ubuntu /opt/odoo-saas
cd /opt/odoo-saas

# Copy all files from this repository
# (git clone or scp)

# Create the environment file
cat > .env <<EOF
POSTGRES_USER=odoo
POSTGRES_PASSWORD=YourSecurePassword123!
EOF

# Set permissions
chmod 600 .env
chmod +x provision_shop.sh backup_all.sh harden_server.sh

# Start the stack
docker compose up -d

# Check health
docker compose ps
docker compose logs --tail=50 odoo
```

---

## Step 3 — Configure Nginx Proxy Manager

1. SSH tunnel: `ssh -L 8081:localhost:81 ubuntu@<VPS_IP>`
2. Open `http://localhost:8081`
3. Default login: `admin@example.com` / `changeme`
4. **Change the admin password immediately**
5. Add your wildcard SSL certificate:
   - SSL Certificates → Add Certificate → Let's Encrypt
   - Domain: `*.yourdomain.com` and `yourdomain.com`
   - Use DNS Challenge with your DNS provider's API key

---

## Step 4 — Generate the Odoo Master Password

```bash
python3 -c "
from passlib.context import CryptContext
pw = input('Enter master password: ')
print(CryptContext(['pbkdf2_sha512']).hash(pw))
"
```

Paste the hash into `odoo/odoo.conf` at the `admin_passwd` line, then restart:
```bash
docker compose restart odoo
```

---

## Step 5 — Provision a New Shop

```bash
export ODOO_MASTER_PW="YourMasterPassword"
export NPM_USER="admin@example.com"
export NPM_PASS="YourNPMPassword"

./provision_shop.sh \
  --shop myshop \
  --domain yourdomain.com \
  --admin-email owner@myshop.com
```

The script will:
1. Create a PostgreSQL database named `myshop`
2. Install Odoo base + `point_of_sale` + `pwa_pos_ios` modules
3. Create an NPM proxy host: `myshop.yourdomain.com → odoo:8069`
4. Issue a Let's Encrypt certificate
5. Print the admin credentials

---

## Step 6 — Install the Custom PWA Module

```bash
# Copy the module to the addons directory
cp -r odoo/addons/pwa_pos_ios /opt/odoo-saas/odoo/addons/

# Install into a specific tenant DB
docker compose exec odoo odoo \
  --db_host=postgres \
  --db_user=odoo \
  --db_password=YourSecurePassword123! \
  -u pwa_pos_ios \
  -d myshop \
  --stop-after-init
```

---

## Step 7 — iPhone PWA Setup (End-User Instructions)

Give these instructions to each shop owner:

1. Open `https://myshop.yourdomain.com` in **Safari** (must be Safari on iOS)
2. Tap the **Share** button (rectangle with arrow pointing up)
3. Scroll down and tap **"Add to Home Screen"**
4. Name it (e.g. "My Shop POS") and tap **Add**
5. Launch the app from the Home Screen icon

The app will now run in **standalone mode** (no address bar, no browser chrome).

### Camera / Scanner permissions

- First scan attempt triggers the iOS camera permission prompt — tap **Allow**
- If denied by mistake: **Settings → Safari → Camera → Allow**
- iPhone X (iOS 15): Safari must have camera access in **Settings → Privacy → Camera → Safari**

---

## QR Scanner: How It Works

The `Html5-Qrcode` library uses `getUserMedia({ video: { facingMode: "environment" } })` to access the rear camera. Key iOS requirements:

| Requirement | Detail |
|---|---|
| **HTTPS** | Mandatory. `getUserMedia` is blocked on HTTP. |
| **User gesture** | `startScanner()` must be called from a tap handler, not `onload`. |
| **iOS 16.4+** | Camera works in PWA standalone mode. |
| **iOS 15** | Camera works but requires explicit Safari permission grant. |
| **iOS < 15** | Not reliably supported. Falls back to manual barcode entry. |

---

## db_filter Mechanics

```
Hostname: shop1.yourdomain.com
  → Odoo extracts first label: "shop1"  (the %d token)
  → db_filter = ^shop1$
  → Only DB named "shop1" is accessible
  → All other databases: invisible, 404 response

Hostname: shop2.yourdomain.com
  → db_filter = ^shop2$
  → DB "shop1" does not exist from shop2's perspective
```

This is enforced server-side in Odoo's HTTP layer — no middleware or database password is needed to achieve tenant isolation.

---

## Backup & Restore

### Manual backup
```bash
./backup_all.sh
# Backups saved to /opt/odoo-saas/backups/
```

### Restore a specific tenant
```bash
SHOP=myshop
BACKUP=/opt/odoo-saas/backups/${SHOP}_20250601-020000.tar.gz

# Extract
tar -xzf "${BACKUP}" -C /tmp/
cd /tmp/${SHOP}_20250601-020000

# Restore database
docker compose exec -T postgres \
  pg_restore -U odoo -d "${SHOP}" --clean dump.pgdump

# Restore filestore
docker compose exec -T odoo \
  tar -xzf - -C /var/lib/odoo/filestore < filestore.tar.gz
```

---

## Monitoring & Troubleshooting

```bash
# Live logs
docker compose logs -f odoo
docker compose logs -f postgres

# Container health
docker compose ps

# Odoo shell (for DB debugging)
docker compose exec odoo odoo shell -d myshop

# Check Fail2Ban status
sudo fail2ban-client status
sudo fail2ban-client status sshd

# UFW status
sudo ufw status verbose

# Force restart the stack
sudo systemctl restart odoo-saas
```

---

## File Structure

```
/opt/odoo-saas/
├── docker-compose.yml          # Main stack definition
├── .env                        # Secrets (not committed to git)
├── provision_shop.sh           # New tenant provisioning script
├── backup_all.sh               # Backup all tenant DBs
├── harden_server.sh            # One-shot server hardening
├── odoo/
│   ├── odoo.conf               # Odoo configuration
│   └── addons/
│       └── pwa_pos_ios/        # Custom PWA + scanner module
│           ├── __manifest__.py
│           ├── views/
│           │   └── web_layout_inherit.xml
│           └── static/src/
│               ├── js/
│               │   ├── qr_scanner_widget.js
│               │   └── pwa_service_worker_register.js
│               └── css/
│                   └── scanner.css
├── postgres/
│   └── init/                   # Optional init SQL scripts
└── backups/                    # Tenant backups (auto-created)
```
