#!/usr/bin/env bash
set -euo pipefail

[[ "$EUID" -ne 0 ]] && { echo "Run as root (sudo bash harden_server.sh)"; exit 1; }

COMPOSE_DIR="${COMPOSE_DIR:-/opt/odoo-saas}"
SSH_PORT="${SSH_PORT:-22}"

echo "=== Odoo SaaS Server Hardening — Ubuntu 24.04 ==="

# 1 — System update
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq ufw fail2ban unattended-upgrades \
    ca-certificates gnupg lsb-release

# 2 — Unattended upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades

# 3 — SSH hardening
SSHD="/etc/ssh/sshd_config"
cp -n "${SSHD}" "${SSHD}.bak"

apply_ssh() {
    local K="$1" V="$2"
    grep -qE "^#?${K}" "${SSHD}" \
        && sed -i "s|^#\?${K}.*|${K} ${V}|" "${SSHD}" \
        || echo "${K} ${V}" >> "${SSHD}"
}

apply_ssh PermitRootLogin no
apply_ssh PasswordAuthentication no
apply_ssh ChallengeResponseAuthentication no
apply_ssh PubkeyAuthentication yes
apply_ssh X11Forwarding no
apply_ssh AllowTcpForwarding no
apply_ssh MaxAuthTries 3
apply_ssh LoginGraceTime 20
apply_ssh ClientAliveInterval 300
apply_ssh ClientAliveCountMax 2

sshd -t && systemctl restart ssh
echo "SSH hardened."

# 4 — UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "SSH"
ufw allow 80/tcp            comment "HTTP"
ufw allow 443/tcp           comment "HTTPS"
ufw --force enable
echo "UFW enabled. Ports: ${SSH_PORT}, 80, 443."

# 5 — Fail2Ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log

[odoo-login]
enabled  = true
port     = http,https
filter   = odoo-login
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 300
bantime  = 1800
EOF

cat > /etc/fail2ban/filter.d/odoo-login.conf <<'EOF'
[Definition]
failregex = <HOST> .* "POST /web/session/authenticate HTTP.*" 200
ignoreregex =
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
echo "Fail2Ban configured."

# 6 — Docker
if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    echo "Docker installed."
else
    echo "Docker already present."
fi
usermod -aG docker ubuntu 2>/dev/null || true

# 7 — Systemd service
mkdir -p "${COMPOSE_DIR}"

cat > /etc/systemd/system/odoo-saas.service <<EOF
[Unit]
Description=Odoo SaaS Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${COMPOSE_DIR}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=30s
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/odoo-backup.service <<'EOF'
[Unit]
Description=Odoo daily backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/odoo-saas/backup_all.sh
EOF

cat > /etc/systemd/system/odoo-backup.timer <<'EOF'
[Unit]
Description=Daily Odoo backup at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable odoo-saas.service
systemctl enable odoo-backup.timer
systemctl start  odoo-backup.timer

echo ""
echo "=== HARDENING COMPLETE ==="
echo "Next: copy project to ${COMPOSE_DIR}, then: systemctl start odoo-saas"
echo "NPM admin on port 81 is NOT exposed in UFW."
echo "Access it via SSH tunnel: ssh -L 8081:localhost:81 ubuntu@<IP>"
