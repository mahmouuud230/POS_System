/** @odoo-module **/
/**
 * File: pwa_pos_ios/static/src/js/pwa_service_worker_register.js
 *
 * Responsibilities
 * ─────────────────
 * 1. Register the Service Worker (enables offline shell + caching)
 * 2. Show the custom Back button when running in iOS Standalone mode
 * 3. Handle the Back button tap using the History API
 *
 * iOS Standalone detection
 * ─────────────────────────
 * window.navigator.standalone === true  →  launched from Home Screen icon
 * This is the ONLY reliable signal on iOS; matchMedia("display-mode: standalone")
 * works on Android/Chrome but NOT on older iOS Safari builds.
 */

(function initPWA() {
    "use strict";

    // ── 1. Service Worker registration ────────────────────────────────────────
    if ("serviceWorker" in navigator) {
        // The SW file is served by the Odoo controller in controllers/pwa.py
        navigator.serviceWorker
            .register("/pwa/sw.js", { scope: "/" })
            .then((reg) => {
                console.log("[PWA] Service Worker registered, scope:", reg.scope);
            })
            .catch((err) => {
                // Non-fatal — app still works without SW
                console.warn("[PWA] SW registration failed:", err);
            });
    }

    // ── 2. iOS Standalone back button ─────────────────────────────────────────
    const isStandalone =
        window.navigator.standalone === true ||
        window.matchMedia("(display-mode: standalone)").matches;

    if (isStandalone) {
        document.addEventListener("DOMContentLoaded", () => {
            const btn = document.getElementById("pwa-back-btn");
            if (!btn) return;

            // Show the button
            btn.classList.remove("d-none");

            // Navigate back on tap
            btn.addEventListener("click", () => {
                if (window.history.length > 1) {
                    window.history.back();
                } else {
                    // At the root — do nothing or navigate to POS home
                    window.location.href = "/web#action=point_of_sale.action_pos_pos_form";
                }
            });

            // Hide the button on the POS home screen (no "back" makes sense there)
            const observer = new MutationObserver(() => {
                const isPosRoot =
                    window.location.hash.includes("pos") &&
                    !window.location.hash.includes("session");
                btn.style.opacity = isPosRoot ? "0" : "1";
                btn.style.pointerEvents = isPosRoot ? "none" : "auto";
            });
            observer.observe(document.body, { subtree: true, childList: true });
        });
    }
})();
