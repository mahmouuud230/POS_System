/** @odoo-module **/
/**
 * File: pwa_pos_ios/static/src/js/qr_scanner_widget.js
 *
 * Implements a QR / Barcode scanner widget for the Odoo 18 POS using the
 * Html5-QrcodeScanner library (https://github.com/mebjas/html5-qrcode).
 *
 * iOS Safari compatibility notes
 * ───────────────────────────────
 * • getUserMedia() requires HTTPS — enforced by our Nginx/NPM stack.
 * • iOS 16.4+ supports camera in Home Screen PWA standalone mode.
 * • iPhone X / iOS 15 requires "Allow camera access" in Settings → Safari.
 * • We must call Html5Qrcode.getCameras() from a user-gesture handler
 *   (button tap), NOT on page load, or Safari silently denies the request.
 * • We request { facingMode: "environment" } to prefer the rear camera.
 * • The library is loaded from the CDN via the asset bundle XML entry.
 *   Alternatively, copy html5-qrcode.min.js into static/lib/ and reference it.
 */

import { Component, useState, onWillUnmount, useRef } from "@odoo/owl";
import { usePos } from "@point_of_sale/app/store/pos_hook";
import { registry } from "@web/core/registry";

// ── Html5-Qrcode CDN shim ────────────────────────────────────────────────────
// The library is bundled via a <script> tag in the asset bundle below so that
// window.Html5Qrcode is available globally by the time this module executes.
// See: pwa_pos_ios/views/web_layout_inherit.xml  (assets entry for CDN script)

const SCAN_REGION_ID = "pwa-qr-scan-region";

export class QrScannerWidget extends Component {
    static template = "pwa_pos_ios.QrScannerWidget";

    setup() {
        this.pos = usePos();
        this.state = useState({
            scanning: false,
            lastResult: "",
            error: "",
            cameraPermission: "unknown", // unknown | granted | denied
        });
        this.html5QrCode = null;
        this.containerRef = useRef("scanContainer");

        onWillUnmount(() => this._stopScanner());
    }

    // ── Public API ────────────────────────────────────────────────────────────

    async startScanner() {
        if (this.state.scanning) return;
        this.state.error = "";

        // Verify the library loaded
        if (typeof window.Html5Qrcode === "undefined") {
            this.state.error =
                "Scanner library not loaded. Check your network connection.";
            return;
        }

        // The scan region <div> must exist in the DOM before we attach
        await this._waitForDom(SCAN_REGION_ID);

        this.html5QrCode = new window.Html5Qrcode(SCAN_REGION_ID);

        const config = {
            fps: 15,
            // qrbox: a square of 250px gives good UX on phones
            qrbox: { width: 250, height: 250 },
            // Scan multiple formats — EAN-13, EAN-8, UPC-A, QR, Code128, etc.
            formatsToSupport: [
                window.Html5QrcodeSupportedFormats.EAN_13,
                window.Html5QrcodeSupportedFormats.EAN_8,
                window.Html5QrcodeSupportedFormats.UPC_A,
                window.Html5QrcodeSupportedFormats.CODE_128,
                window.Html5QrcodeSupportedFormats.CODE_39,
                window.Html5QrcodeSupportedFormats.QR_CODE,
            ],
            // Smooth false positives
            experimentalFeatures: { useBarCodeDetectorIfSupported: true },
        };

        try {
            // IMPORTANT: must be called from a user-gesture callback on iOS
            await this.html5QrCode.start(
                { facingMode: "environment" },  // rear camera
                config,
                this._onScanSuccess.bind(this),
                this._onScanError.bind(this)    // quiet; fires on every frame
            );
            this.state.scanning = true;
            this.state.cameraPermission = "granted";
        } catch (err) {
            console.error("[QrScanner] start failed:", err);
            if (
                err.includes("NotAllowedError") ||
                err.name === "NotAllowedError"
            ) {
                this.state.cameraPermission = "denied";
                this.state.error =
                    "Camera permission denied. " +
                    "On iPhone: Settings → Safari → Camera → Allow.";
            } else {
                this.state.error = `Camera error: ${err}`;
            }
        }
    }

    async stopScanner() {
        await this._stopScanner();
        this.state.scanning = false;
    }

    // ── Scan callbacks ────────────────────────────────────────────────────────

    _onScanSuccess(decodedText /*, decodedResult */) {
        // Deduplicate rapid-fire scans of the same code
        if (decodedText === this.state.lastResult) return;
        this.state.lastResult = decodedText;

        // Haptic feedback on iOS (requires user gesture origin — the scan IS one)
        if (navigator.vibrate) navigator.vibrate(40);

        // Hand off to POS: look up product by barcode
        this._processBarcodeInPos(decodedText);

        // Auto-stop after a successful scan (re-tap to scan another item)
        this._stopScanner().then(() => (this.state.scanning = false));
    }

    _onScanError(/* errorMessage */) {
        // Fires on every video frame that isn't a valid barcode — ignore silently
    }

    // ── POS integration ───────────────────────────────────────────────────────

    _processBarcodeInPos(barcode) {
        /**
         * Odoo 18 POS exposes pos.barcodeReader.scan() which looks up products,
         * loyalty cards, customers, etc. and dispatches the appropriate action.
         *
         * Fallback: if your build doesn't expose barcodeReader, use:
         *   this.pos.addProductToOrder(barcode);
         */
        if (this.pos.barcodeReader) {
            this.pos.barcodeReader.scan(barcode);
        } else {
            // Minimal fallback — search order lines by barcode
            const product = this.pos.db.getProductByBarcode(barcode);
            if (product) {
                this.pos.get_order().add_product(product);
            } else {
                this.state.error = `No product found for barcode: ${barcode}`;
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    async _stopScanner() {
        if (this.html5QrCode && this.html5QrCode.isScanning) {
            await this.html5QrCode.stop().catch(console.warn);
            this.html5QrCode.clear();
        }
    }

    _waitForDom(id, timeoutMs = 2000) {
        return new Promise((resolve, reject) => {
            const el = document.getElementById(id);
            if (el) return resolve(el);
            const obs = new MutationObserver(() => {
                const el2 = document.getElementById(id);
                if (el2) { obs.disconnect(); resolve(el2); }
            });
            obs.observe(document.body, { childList: true, subtree: true });
            setTimeout(() => { obs.disconnect(); reject("Timeout waiting for scan region"); }, timeoutMs);
        });
    }
}

// ── OWL template (inline for single-file convenience) ────────────────────────
// In a real module, move this to static/src/xml/qr_scanner.xml
QrScannerWidget.template = /* xml */ `
<div class="pwa-scanner-widget">
    <div t-if="state.error" class="pwa-scanner-error alert alert-danger" role="alert">
        <t t-esc="state.error"/>
    </div>

    <div t-if="!state.scanning" class="pwa-scanner-trigger">
        <button class="btn btn-primary btn-lg pwa-scan-btn"
                t-on-click="startScanner"
                aria-label="Scan barcode or QR code">
            <!-- Camera icon -->
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
                 viewBox="0 0 24 24" fill="none" stroke="currentColor"
                 stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
                 aria-hidden="true">
                <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                <circle cx="12" cy="13" r="4"/>
            </svg>
            Scan Item
        </button>
    </div>

    <!-- The library renders the video feed into this div -->
    <div t-if="state.scanning" class="pwa-scan-viewport">
        <div id="${SCAN_REGION_ID}" class="pwa-scan-region"></div>
        <button class="btn btn-outline-secondary btn-sm mt-2"
                t-on-click="stopScanner">
            Cancel
        </button>
    </div>

    <div t-if="state.lastResult" class="pwa-scan-result text-success">
        ✓ <t t-esc="state.lastResult"/>
    </div>
</div>
`;

// Register as a POS component so it can be added to the POS screen
registry.category("pos_component").add("QrScannerWidget", QrScannerWidget);


/* ─────────────────────────────────────────────────────────────────────────────
   HOW TO ADD THIS BUTTON TO THE POS SCREEN
   ─────────────────────────────────────────────────────────────────────────────
   In Odoo 18 the POS UI is fully OWL-based. To inject the scanner button into
   the ProductScreen, create:

     static/src/js/pos_product_screen_patch.js

   with:

     import { patch } from "@web/core/utils/patch";
     import { ProductScreen } from "@point_of_sale/app/screens/product_screen/product_screen";
     import { QrScannerWidget } from "./qr_scanner_widget";

     patch(ProductScreen, {
         components: {
             ...ProductScreen.components,
             QrScannerWidget,
         },
     });

   And in the ProductScreen template XML, add:
     <QrScannerWidget/>

   ─────────────────────────────────────────────────────────────────────────────
   HTML5-QRCODE CDN LOADING
   ─────────────────────────────────────────────────────────────────────────────
   Add to your assets in __manifest__.py (or ir.asset record):

     'point_of_sale.assets': [
         ('include', 'https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js'),
     ],

   Alternatively, download and store locally:
     static/lib/html5-qrcode.min.js

   Then reference:
     'pwa_pos_ios/static/lib/html5-qrcode.min.js',
   ───────────────────────────────────────────────────────────────────────────── */
