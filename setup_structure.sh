#!/usr/bin/env bash
# =============================================================================
# setup_structure.sh
#
# Organizes the Odoo project files into the expected directory structure.
# =============================================================================

set -e

PROJECT_DIR="/opt/odoo-saas"
MODULE_DIR="${PROJECT_DIR}/odoo/addons/pwa_pos_ios"

echo "Creating directory structure..."
sudo mkdir -p "${MODULE_DIR}"

echo "Moving configuration file..."
if [ -f "${PROJECT_DIR}/odoo.conf" ]; then
    sudo mv "${PROJECT_DIR}/odoo.conf" "${PROJECT_DIR}/odoo/odoo.conf"
    echo "  ✓ odoo.conf moved."
else
    echo "  ℹ odoo.conf not found in root (skipping)."
fi

echo "Moving Odoo module files..."
# Move specific module files if they exist in the root
FILES=(
    "__manifest__.py"
    "pwa_service_worker_register.js"
    "qr_scanner_widget.js"
    "scanner.css"
    "web_layout_inherit.xml"
)

for FILE in "${FILES[@]}"; do
    if [ -f "${PROJECT_DIR}/${FILE}" ]; then
        sudo mv "${PROJECT_DIR}/${FILE}" "${MODULE_DIR}/"
        echo "  ✓ ${FILE} moved."
    fi
done

# Catch any remaining asset files
if ls "${PROJECT_DIR}"/*.js "${PROJECT_DIR}"/*.css "${PROJECT_DIR}"/*.xml 1> /dev/null 2>&1; then
    sudo mv "${PROJECT_DIR}"/*.js "${PROJECT_DIR}"/*.css "${PROJECT_DIR}"/*.xml "${MODULE_DIR}/" 2>/dev/null || true
fi

echo "════════════════════════════════════════"
echo "  ✓ Project structure organized."
echo "  Config: ${PROJECT_DIR}/odoo/odoo.conf"
echo "  Addons: ${MODULE_DIR}/"
echo "════════════════════════════════════════"
