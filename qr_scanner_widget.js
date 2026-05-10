/** @odoo-module **/

import { Component, useState, onWillUnmount } from "@odoo/owl";
import { usePos } from "@point_of_sale/app/store/pos_hook";
import { registry } from "@web/core/registry";

const SCAN_REGION_ID = "pwa-qr-scan-region";

export class QrScannerWidget extends Component {
    static template = "pwa_pos_ios.QrScannerWidget";

    setup() {
        this.pos = usePos();
        this.state = useState({
            scanning: false,
            lastResult: "",
            error: "",
        });
        this.html5QrCode = null;
        onWillUnmount(() => this._stopScanner());
    }

    async startScanner() {
        if (this.state.scanning) return;
        this.state.error = "";

        if (typeof window.Html5Qrcode === "undefined") {
            this.state.error = "Scanner library not loaded. Check network connection.";
            return;
        }

        await this._waitForDom(SCAN_REGION_ID);
        this.html5QrCode = new window.Html5Qrcode(SCAN_REGION_ID);

        const config = {
            fps: 15,
            qrbox: { width: 250, height: 250 },
            formatsToSupport: [
                window.Html5QrcodeSupportedFormats.EAN_13,
                window.Html5QrcodeSupportedFormats.EAN_8,
                window.Html5QrcodeSupportedFormats.UPC_A,
                window.Html5QrcodeSupportedFormats.CODE_128,
                window.Html5QrcodeSupportedFormats.CODE_39,
                window.Html5QrcodeSupportedFormats.QR_CODE,
            ],
            experimentalFeatures: { useBarCodeDetectorIfSupported: true },
        };

        try {
            await this.html5QrCode.start(
                { facingMode: "environment" },
                config,
                this._onScanSuccess.bind(this),
                () => {}
            );
            this.state.scanning = true;
        } catch (err) {
            const msg = err.toString ? err.toString() : String(err);
            if (msg.includes("NotAllowedError")) {
                this.state.error = "Camera denied. On iPhone: Settings → Safari → Camera → Allow.";
            } else {
                this.state.error = "Camera error: " + msg;
            }
        }
    }

    async stopScanner() {
        await this._stopScanner();
        this.state.scanning = false;
    }

    _onScanSuccess(decodedText) {
        if (decodedText === this.state.lastResult) return;
        this.state.lastResult = decodedText;
        if (navigator.vibrate) navigator.vibrate(40);
        this._processBarcodeInPos(decodedText);
        this._stopScanner().then(() => (this.state.scanning = false));
    }

    _processBarcodeInPos(barcode) {
        if (this.pos.barcodeReader) {
            this.pos.barcodeReader.scan(barcode);
        } else {
            const product = this.pos.db.getProductByBarcode(barcode);
            if (product) {
                this.pos.get_order().add_product(product);
            } else {
                this.state.error = "No product found for: " + barcode;
            }
        }
    }

    async _stopScanner() {
        if (this.html5QrCode && this.html5QrCode.isScanning) {
            await this.html5QrCode.stop().catch(() => {});
            this.html5QrCode.clear();
        }
    }

    _waitForDom(id, timeoutMs = 2000) {
        return new Promise((resolve, reject) => {
            const el = document.getElementById(id);
            if (el) return resolve(el);
            const obs = new MutationObserver(() => {
                const found = document.getElementById(id);
                if (found) { obs.disconnect(); resolve(found); }
            });
            obs.observe(document.body, { childList: true, subtree: true });
            setTimeout(() => { obs.disconnect(); reject("Timeout"); }, timeoutMs);
        });
    }
}

QrScannerWidget.template = /* xml */ `
<div class="pwa-scanner-widget">
    <div t-if="state.error" class="alert alert-danger" style="font-size:0.85rem;padding:8px 12px;">
        <t t-esc="state.error"/>
    </div>
    <div t-if="!state.scanning">
        <button class="btn btn-primary" style="display:inline-flex;align-items:center;gap:8px;touch-action:manipulation;"
                t-on-click="startScanner">
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24"
                 fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
                 stroke-linejoin="round" aria-hidden="true">
                <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/>
                <circle cx="12" cy="13" r="4"/>
            </svg>
            Scan Item
        </button>
    </div>
    <div t-if="state.scanning" style="display:flex;flex-direction:column;align-items:center;gap:8px;">
        <div id="${SCAN_REGION_ID}" style="width:100%;max-width:320px;border-radius:12px;overflow:hidden;border:2px solid #714B67;background:#000;"></div>
        <button class="btn btn-outline-secondary btn-sm" t-on-click="stopScanner">Cancel</button>
    </div>
    <div t-if="state.lastResult" style="color:green;font-size:0.9rem;font-weight:600;margin-top:8px;">
        ✓ <t t-esc="state.lastResult"/>
    </div>
</div>
`;

registry.category("pos_component").add("QrScannerWidget", QrScannerWidget);
