#!/usr/bin/env bash
# =============================================================================
# harden_server.sh
#
# One-shot server hardening for Ubuntu 24.04 LTS
#  1. Enforce SSH key-only authentication
#  2. Configure UFW (allow 22, 80, 443; deny everything else)
#  3. Install and configure Fail2Ban for SSH + Nginx brute-force
#  4. Enable automatic unattended security upgrades
#  5. Install Docker + Docker Compose plugin (if not present)
#  6. Configure systemd to auto-restart the Docker Compose stack
#
# Run as root on a fresh Ubuntu 24.04 VPS:
#   curl -fsSL https://your-deploy-url/harden_server.sh | sudo bash
# =============================================================================

set -euo pipefail

# ── Sanity check ──────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && { echo "Run as root (sudo)"; exit 1; }

COMPOSE_DIR="${COMPOSE_DIR:-/opt/odoo-saas}"
SSH_PORT="${SSH_PORT:-22}"

echo ""
echo "═══════════════════════════════════════════════"
echo "  Odoo SaaS — Server Hardening (Ubuntu 24.04)"
echo "═══════════════════════════════════════════════"

# ── 1. System updates ─────────────────────────────────────────────────────────
echo "→ [1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git jq unzip \
    ufw fail2ban \
    unattended-upgrades apt-listchanges \
    ca-certificates gnupg lsb-release

# ── 2. Unattended security upgrades ──────────────────────────────────────────
echo "→ [2/7] Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# ── 3. SSH hardening ──────────────────────────────────────────────────────────
echo "→ [3/7] Hardening SSH..."
SSHD_CONF="/etc/ssh/sshd_config"

# Back up original
cp -n "${SSHD_CONF}" "${SSHD_CONF}.bak"

# Apply hardened settings (idempotent — uses sed to replace or append)
apply_ssh_setting() {
    local KEY="$1" VALUE="$2"
    if grep -qE "^#?${KEY}" "${SSHD_CONF}"; then
        sed -i "s|^#\?${KEY}.*|${KEY} ${VALUE}|" "${SSHD_CONF}"
    else
        echo "${KEY} ${VALUE}" >> "${SSHD_CONF}"
    fi
}

apply_ssh_setting "PermitRootLogin"            "no"
apply_ssh_setting "PasswordAuthentication"     "no"
apply_ssh_setting "ChallengeResponseAuthentication" "no"
apply_ssh_setting "PubkeyAuthentication"       "yes"
apply_ssh_setting "X11Forwarding"              "no"
apply_ssh_setting "AllowTcpForwarding"         "no"
apply_ssh_setting "MaxAuthTries"               "3"
apply_ssh_setting "LoginGraceTime"             "20"
apply_ssh_setting "ClientAliveInterval"        "300"
apply_ssh_setting "ClientAliveCountMax"        "2"

# Validate config before restarting
sshd -t && systemctl restart ssh
echo "   ✓ SSH hardened. KEY-ONLY auth enforced. Root login disabled."

# ── 4. UFW firewall ───────────────────────────────────────────────────────────
echo "→ [4/7] Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp" comment "SSH"
ufw allow 80/tcp            comment "HTTP (redirect to HTTPS)"
ufw allow 443/tcp           comment "HTTPS"
# Port 81 (NPM admin) is intentionally NOT opened here.
# Access NPM via SSH tunnel: ssh -L 8081:localhost:81 user@server

ufw --force enable
ufw status verbose
echo "   ✓ UFW enabled. Ports open: ${SSH_PORT}, 80, 443."
echo "   ℹ NPM port 81 NOT exposed. Use SSH tunnel for initial setup."

# ── 5. Fail2Ban ───────────────────────────────────────────────────────────────
echo "→ [5/7] Configuring Fail2Ban..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

# ── SSH ──────────────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = /var/log/auth.log
maxretry = 3

# ── Nginx (generic HTTP auth brute-force) ────────────────────────────────────
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log

# ── Odoo database manager (/web/database/) ───────────────────────────────────
[odoo-dbmanager]
enabled  = true
port     = http,https
filter   = odoo-dbmanager
logpath  = /var/log/nginx/access.log
maxretry = 3
bantime  = 7200

# ── Odoo web login ────────────────────────────────────────────────────────────
[odoo-login]
enabled  = true
port     = http,https
filter   = odoo-login
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 300
bantime  = 1800
EOF

# Custom filter: Odoo DB manager 403/302 probing
cat > /etc/fail2ban/filter.d/odoo-dbmanager.conf <<'EOF'
[Definition]
failregex = <HOST> .* "POST /web/database/.* HTTP.*" (400|403|500)
ignoreregex =
EOF

# Custom filter: repeated Odoo login failures (Odoo logs 200 but with error JSON)
cat > /etc/fail2ban/filter.d/odoo-login.conf <<'EOF'
[Definition]
failregex = <HOST> .* "POST /web/session/authenticate HTTP.*" 200
ignoreregex =
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
echo "   ✓ Fail2Ban running. SSH, Nginx, and Odoo jails active."

# ── 6. Install Docker ─────────────────────────────────────────────────────────
echo "→ [6/7] Installing Docker CE + Compose plugin..."
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    echo "   ✓ Docker installed."
else
    echo "   ✓ Docker already installed ($(docker --version))."
fi

# Add ubuntu user to docker group
usermod -aG docker ubuntu 2>/dev/null || true

# ── 7. Systemd service for the Compose stack ──────────────────────────────────
echo "→ [7/7] Creating systemd service for Odoo SaaS stack..."

mkdir -p "${COMPOSE_DIR}"

cat > /etc/systemd/system/odoo-saas.service <<EOF
[Unit]
Description=Odoo SaaS Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${COMPOSE_DIR}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose pull && /usr/bin/docker compose up -d --remove-orphans
Restart=on-failure
RestartSec=30s
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

# Automated daily backup service (runs at 02:00 local time)
cat > /etc/systemd/system/odoo-backup.service <<'BEOF'
[Unit]
Description=Daily Odoo database and filestore backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/odoo-saas/backup_all.sh
StandardOutput=journal
StandardError=journal
BEOF

cat > /etc/systemd/system/odoo-backup.timer <<'TEOF'
[Unit]
Description=Run Odoo backup daily at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
TEOF

systemctl daemon-reload
systemctl enable odoo-saas.service
systemctl enable odoo-backup.timer
systemctl start  odoo-backup.timer

echo "   ✓ Systemd units created and enabled."
echo "     odoo-saas.service  → starts stack on boot, restarts on failure"
echo "     odoo-backup.timer  → daily backup at 02:00"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✓ SERVER HARDENED SUCCESSFULLY"
echo ""
echo "  Next steps:"
echo "  1. Copy your project to ${COMPOSE_DIR}"
echo "  2. Set .env variables (POSTGRES_PASSWORD, ODOO_MASTER_PW)"
echo "  3. systemctl start odoo-saas"
echo "  4. SSH tunnel to NPM: ssh -L 8081:localhost:81 ubuntu@<IP>"
echo "     Then open http://localhost:8081 to configure proxy hosts"
echo "  5. Run ./provision_shop.sh to create your first tenant"
echo "═══════════════════════════════════════════════════════════"
