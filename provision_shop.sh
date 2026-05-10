#!/usr/bin/env bash
# =============================================================================
# provision_shop.sh
#
# Automates creation of a new POS shop tenant on the Odoo SaaS stack.
#
# What it does
# ─────────────
#  1. Creates a new Odoo database for the shop via the /web/database/create API
#  2. Waits for Odoo to initialise the DB (installs base modules)
#  3. Installs point_of_sale + pwa_pos_ios modules into the new DB
#  4. Creates an Nginx Proxy Manager proxy host via the NPM API
#     (shop.yourdomain.com → odoo:8069)
#  5. Triggers Let's Encrypt SSL certificate issuance
#  6. Prints the shop URL and admin credentials
#
# Usage
# ──────
#   chmod +x provision_shop.sh
#   ./provision_shop.sh --shop myshop --domain yourdomain.com \
#                       --admin-email owner@myshop.com
#
# Requirements
# ─────────────
#   • docker compose stack is running  (docker compose up -d)
#   • jq  (apt install -y jq)
#   • curl
#   • The NPM admin credentials exported or passed via --npm-user / --npm-pass
#   • Wildcard DNS *.yourdomain.com already pointing to this server's IP
# =============================================================================

set -euo pipefail

# ── Defaults (override via flags) ─────────────────────────────────────────────
ODOO_MASTER_PW="${ODOO_MASTER_PW:-}"          # Set in env or via --master-pw
NPM_USER="${NPM_USER:-admin@example.com}"
NPM_PASS="${NPM_PASS:-changeme}"
NPM_BASE="http://localhost:81"
ODOO_BASE="http://localhost:8069"
SHOP_NAME=""
DOMAIN=""
ADMIN_EMAIL=""
ADMIN_PASS=""

# ── Argument parsing ──────────────────────────────────────────────────────────
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

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "$SHOP_NAME" ]]  && { echo "ERROR: --shop is required";  exit 1; }
[[ -z "$DOMAIN" ]]     && { echo "ERROR: --domain is required"; exit 1; }
[[ -z "$ODOO_MASTER_PW" ]] && { echo "ERROR: ODOO_MASTER_PW is not set"; exit 1; }

# Sanitise: shop name becomes the DB name (lowercase, alphanum + dash only)
SHOP_NAME="${SHOP_NAME,,}"                         # lowercase
SHOP_NAME="${SHOP_NAME//[^a-z0-9-]/-}"            # replace invalid chars
SHOP_NAME="${SHOP_NAME#-}"; SHOP_NAME="${SHOP_NAME%-}" # trim leading/trailing dash

FQDN="${SHOP_NAME}.${DOMAIN}"

# Auto-generate admin password if not supplied
if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
fi

# Auto-derive admin email if not supplied
if [[ -z "$ADMIN_EMAIL" ]]; then
    ADMIN_EMAIL="admin@${FQDN}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Provisioning shop: ${SHOP_NAME}"
echo "  FQDN:              ${FQDN}"
echo "  Admin email:       ${ADMIN_EMAIL}"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Helper: wait for Odoo HTTP ────────────────────────────────────────────────
wait_for_odoo() {
    local retries=30
    echo -n "Waiting for Odoo... "
    until curl -sf "${ODOO_BASE}/web/health" > /dev/null 2>&1; do
        ((retries--)) || { echo "TIMEOUT"; exit 1; }
        sleep 3
        echo -n "."
    done
    echo " OK"
}

# ── Step 1: Create Odoo Database ──────────────────────────────────────────────
echo "→ [1/5] Creating Odoo database '${SHOP_NAME}'..."

wait_for_odoo

HTTP_STATUS=$(curl -s -o /tmp/odoo_create.log -w "%{http_code}" \
    -X POST "${ODOO_BASE}/web/database/create" \
    -F "master_pwd=${ODOO_MASTER_PW}" \
    -F "name=${SHOP_NAME}" \
    -F "lang=en_US" \
    -F "password=${ADMIN_PASS}" \
    -F "login=${ADMIN_EMAIL}" \
    -F "phone=" \
    -F "demo=false")

if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "   ✓ Database created."
elif [[ "$HTTP_STATUS" == "303" ]] || [[ "$HTTP_STATUS" == "302" ]]; then
    # Odoo redirects on success
    echo "   ✓ Database created (redirect response, normal)."
else
    echo "   ✗ Failed (HTTP ${HTTP_STATUS}). Response:"
    cat /tmp/odoo_create.log
    exit 1
fi

# ── Step 2: Wait for DB initialisation ────────────────────────────────────────
echo "→ [2/5] Waiting 20 s for base module installation..."
sleep 20

# ── Step 3: Install POS + PWA module ─────────────────────────────────────────
echo "→ [3/5] Installing point_of_sale and pwa_pos_ios modules..."

# Authenticate as admin in the new DB
SESSION=$(curl -sc /tmp/session.jar -s \
    -X POST "${ODOO_BASE}/web/session/authenticate" \
    -H "Content-Type: application/json" \
    -d "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"call\",
        \"params\": {
            \"db\": \"${SHOP_NAME}\",
            \"login\": \"${ADMIN_EMAIL}\",
            \"password\": \"${ADMIN_PASS}\"
        }
    }")

# Extract session id
SESSION_ID=$(echo "$SESSION" | jq -r '.result.session_id // empty')
if [[ -z "$SESSION_ID" ]]; then
    echo "   ✗ Authentication failed. Check admin credentials."
    echo "$SESSION" | jq .
    exit 1
fi
echo "   ✓ Authenticated (session: ${SESSION_ID:0:8}...)"

# Install modules via /web/dataset/call_kw
install_module() {
    local MODULE="$1"
    echo -n "   Installing ${MODULE}... "
    curl -sb /tmp/session.jar -s \
        -X POST "${ODOO_BASE}/web/dataset/call_kw" \
        -H "Content-Type: application/json" \
        -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"call\",
            \"params\": {
                \"model\": \"ir.module.module\",
                \"method\": \"button_immediate_install\",
                \"args\": [],
                \"kwargs\": {
                    \"domain\": [[\"name\", \"=\", \"${MODULE}\"]]
                }
            }
        }" > /tmp/install_${MODULE}.log
    # Odoo may return a client action or just {result: false} on success
    local ERR
    ERR=$(jq -r '.error.message // empty' /tmp/install_${MODULE}.log)
    if [[ -n "$ERR" ]]; then
        echo "FAILED: ${ERR}"
    else
        echo "done."
    fi
}

install_module "point_of_sale"
# Install our custom PWA module (only if present in addons path)
install_module "pwa_pos_ios" || echo "   (pwa_pos_ios not found in addons — skipping)"

# ── Step 4: Configure Nginx Proxy Manager proxy host ─────────────────────────
echo "→ [4/5] Creating NPM proxy host for ${FQDN}..."

# Authenticate with NPM
NPM_TOKEN=$(curl -s -X POST "${NPM_BASE}/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\": \"${NPM_USER}\", \"secret\": \"${NPM_PASS}\"}" \
    | jq -r '.token')

if [[ -z "$NPM_TOKEN" || "$NPM_TOKEN" == "null" ]]; then
    echo "   ✗ NPM authentication failed. Check NPM_USER / NPM_PASS."
    exit 1
fi
echo "   ✓ NPM authenticated."

# Create the proxy host
PROXY_RESPONSE=$(curl -s -X POST "${NPM_BASE}/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${NPM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"domain_names\": [\"${FQDN}\"],
        \"forward_scheme\": \"http\",
        \"forward_host\": \"odoo\",
        \"forward_port\": 8069,
        \"access_list_id\": 0,
        \"certificate_id\": 0,
        \"ssl_forced\": true,
        \"hsts_enabled\": true,
        \"hsts_subdomains\": false,
        \"http2_support\": true,
        \"block_exploits\": true,
        \"caching_enabled\": false,
        \"allow_websocket_upgrade\": true,
        \"locations\": [
            {
                \"path\": \"/websocket\",
                \"forward_scheme\": \"http\",
                \"forward_host\": \"odoo\",
                \"forward_port\": 8072,
                \"websocket\": true
            }
        ],
        \"advanced_config\": \"proxy_set_header X-Forwarded-Host \\$host;\\nproxy_set_header X-Real-IP \\$remote_addr;\\nproxy_read_timeout 720s;\\nproxy_connect_timeout 720s;\\nclient_max_body_size 128m;\"
    }")

PROXY_ID=$(echo "$PROXY_RESPONSE" | jq -r '.id // empty')
if [[ -z "$PROXY_ID" ]]; then
    echo "   ✗ Proxy host creation failed:"
    echo "$PROXY_RESPONSE" | jq .
    exit 1
fi
echo "   ✓ Proxy host created (ID: ${PROXY_ID})."

# ── Step 5: Request Let's Encrypt certificate ─────────────────────────────────
echo "→ [5/5] Requesting Let's Encrypt SSL certificate for ${FQDN}..."

CERT_RESPONSE=$(curl -s -X POST "${NPM_BASE}/api/nginx/certificates" \
    -H "Authorization: Bearer ${NPM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"provider\": \"letsencrypt\",
        \"domain_names\": [\"${FQDN}\"],
        \"meta\": {
            \"letsencrypt_email\": \"${ADMIN_EMAIL}\",
            \"letsencrypt_agree\": true
        }
    }")

CERT_ID=$(echo "$CERT_RESPONSE" | jq -r '.id // empty')

if [[ -n "$CERT_ID" && "$CERT_ID" != "null" ]]; then
    echo "   ✓ Certificate issued (ID: ${CERT_ID})."
    # Attach the certificate to the proxy host
    curl -s -X PUT "${NPM_BASE}/api/nginx/proxy-hosts/${PROXY_ID}" \
        -H "Authorization: Bearer ${NPM_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"certificate_id\": ${CERT_ID}, \"ssl_forced\": true}" > /dev/null
    echo "   ✓ SSL attached to proxy host."
else
    echo "   ⚠ Certificate request failed or pending. Check NPM UI."
    echo "     (DNS for ${FQDN} must resolve to this server first)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✓ SHOP PROVISIONED SUCCESSFULLY"
echo ""
echo "  URL:            https://${FQDN}"
echo "  Odoo DB:        ${SHOP_NAME}"
echo "  Admin login:    ${ADMIN_EMAIL}"
echo "  Admin password: ${ADMIN_PASS}"
echo ""
echo "  NEXT STEPS:"
echo "  1. Log in at https://${FQDN}/web"
echo "  2. Go to Point of Sale → Configuration → Settings"
echo "  3. Open a POS session and test the QR scanner"
echo "  4. Add to iPhone Home Screen: Share → Add to Home Screen"
echo "═══════════════════════════════════════════════════════════"
echo ""
