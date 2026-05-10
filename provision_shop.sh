#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# provision_shop.sh — Create a new POS tenant
#
# Usage:
#   ./provision_shop.sh --shop myshop --domain yourdomain.com
#
# Optional overrides (defaults read from .env in script directory):
#   --admin-email owner@shop.com
#   --admin-pass  SecretPass123
#   --master-pw   OdooMaster_2025!
#   --npm-user    admin@example.com
#   --npm-pass    NpmAdmin_2025!
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Load .env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

ODOO_MASTER_PW="${ODOO_MASTER_PW:-}"
NPM_USER="${NPM_USER:-admin@example.com}"
NPM_PASS="${NPM_PASS:-changeme}"
NPM_BASE="http://localhost:81"
ODOO_BASE="http://localhost:8069"
SHOP_NAME=""
DOMAIN=""
ADMIN_EMAIL=""
ADMIN_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shop)        SHOP_NAME="$2";       shift 2 ;;
        --domain)      DOMAIN="$2";          shift 2 ;;
        --admin-email) ADMIN_EMAIL="$2";     shift 2 ;;
        --admin-pass)  ADMIN_PASS="$2";      shift 2 ;;
        --master-pw)   ODOO_MASTER_PW="$2";  shift 2 ;;
        --npm-user)    NPM_USER="$2";        shift 2 ;;
        --npm-pass)    NPM_PASS="$2";        shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

[[ -z "$SHOP_NAME" ]]       && { echo "ERROR: --shop is required";        exit 1; }
[[ -z "$DOMAIN" ]]          && { echo "ERROR: --domain is required";      exit 1; }
[[ -z "$ODOO_MASTER_PW" ]] && { echo "ERROR: ODOO_MASTER_PW not set";   exit 1; }

SHOP_NAME="${SHOP_NAME,,}"
SHOP_NAME="${SHOP_NAME//[^a-z0-9-]/-}"
SHOP_NAME="${SHOP_NAME#-}"; SHOP_NAME="${SHOP_NAME%-}"
FQDN="${SHOP_NAME}.${DOMAIN}"

[[ -z "$ADMIN_PASS" ]]  && ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
[[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${FQDN}"

echo ""
echo "=== Provisioning: ${SHOP_NAME} at ${FQDN} ==="
echo ""

wait_for_odoo() {
    local n=40
    echo -n "Waiting for Odoo "
    until curl -sf "${ODOO_BASE}/web/health" >/dev/null 2>&1; do
        ((n--)) || { echo " TIMEOUT"; exit 1; }
        sleep 3; echo -n "."
    done
    echo " OK"
}

# 1 — Create database
echo "-> [1/5] Creating database '${SHOP_NAME}'..."
wait_for_odoo

STATUS=$(curl -s -o /tmp/odoo_create.log -w "%{http_code}" \
    -X POST "${ODOO_BASE}/web/database/create" \
    -F "master_pwd=${ODOO_MASTER_PW}" \
    -F "name=${SHOP_NAME}" \
    -F "lang=en_US" \
    -F "password=${ADMIN_PASS}" \
    -F "login=${ADMIN_EMAIL}" \
    -F "phone=" \
    -F "demo=false")

case "$STATUS" in
    200|302|303) echo "   OK (HTTP ${STATUS})" ;;
    *) echo "   FAILED (HTTP ${STATUS})"; cat /tmp/odoo_create.log; exit 1 ;;
esac

# 2 — Wait for base install
echo "-> [2/5] Waiting 25s for base modules to install..."
sleep 25

# 3 — Authenticate and install POS module
echo "-> [3/5] Installing point_of_sale module..."

AUTH=$(curl -sc /tmp/cookies.jar -s \
    -X POST "${ODOO_BASE}/web/session/authenticate" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":{\"db\":\"${SHOP_NAME}\",\"login\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}}")

SID=$(echo "$AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['session_id'])" 2>/dev/null || true)
[[ -z "$SID" ]] && { echo "   FAILED: auth error"; echo "$AUTH"; exit 1; }
echo "   Authenticated."

install_module() {
    local MOD="$1"
    echo -n "   Installing ${MOD}... "
    curl -sb /tmp/cookies.jar -s \
        -X POST "${ODOO_BASE}/web/dataset/call_kw" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":{\"model\":\"ir.module.module\",\"method\":\"button_immediate_install\",\"args\":[],\"kwargs\":{\"domain\":[[\"name\",\"=\",\"${MOD}\"]]}}}" \
        > /tmp/install_${MOD}.log
    local ERR
    ERR=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" < /tmp/install_${MOD}.log 2>/dev/null || true)
    [[ -n "$ERR" ]] && echo "WARN: ${ERR}" || echo "done"
}

install_module "point_of_sale"
install_module "pwa_pos_ios" || echo "   (pwa_pos_ios not found in addons path, skipping)"

# 4 — Create NPM proxy host
echo "-> [4/5] Creating Nginx proxy host for ${FQDN}..."

TOKEN=$(curl -s -X POST "${NPM_BASE}/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

[[ -z "$TOKEN" ]] && { echo "   NPM auth failed — skipping proxy setup"; } || {

    PROXY=$(curl -s -X POST "${NPM_BASE}/api/nginx/proxy-hosts" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain_names\":[\"${FQDN}\"],
            \"forward_scheme\":\"http\",
            \"forward_host\":\"odoo\",
            \"forward_port\":8069,
            \"ssl_forced\":true,
            \"http2_support\":true,
            \"block_exploits\":true,
            \"allow_websocket_upgrade\":true,
            \"advanced_config\":\"proxy_set_header X-Forwarded-Host \$host;\nproxy_read_timeout 720s;\nclient_max_body_size 128m;\"
        }")

    PID=$(echo "$PROXY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    [[ -n "$PID" ]] && echo "   Proxy host created (ID: ${PID})" || echo "   Proxy creation warn: ${PROXY}"

    # 5 — Request SSL cert
    echo "-> [5/5] Requesting Let's Encrypt certificate..."
    CERT=$(curl -s -X POST "${NPM_BASE}/api/nginx/certificates" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"provider\":\"letsencrypt\",\"domain_names\":[\"${FQDN}\"],\"meta\":{\"letsencrypt_email\":\"${ADMIN_EMAIL}\",\"letsencrypt_agree\":true}}")

    CID=$(echo "$CERT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    if [[ -n "$CID" && "$CID" != "None" ]]; then
        echo "   Certificate issued (ID: ${CID})"
        curl -s -X PUT "${NPM_BASE}/api/nginx/proxy-hosts/${PID}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"certificate_id\":${CID},\"ssl_forced\":true}" > /dev/null
        echo "   SSL attached."
    else
        echo "   Certificate pending — ensure DNS for ${FQDN} points here first."
    fi
}

echo ""
echo "========================================"
echo "  SHOP READY"
echo "  URL:      https://${FQDN}"
echo "  DB:       ${SHOP_NAME}"
echo "  Login:    ${ADMIN_EMAIL}"
echo "  Password: ${ADMIN_PASS}"
echo "========================================"
