/** @odoo-module **/

(function initPWA() {
    "use strict";

    if ("serviceWorker" in navigator) {
        navigator.serviceWorker
            .register("/pwa/sw.js", { scope: "/" })
            .catch(function (err) {
                console.warn("[PWA] SW registration failed:", err);
            });
    }

    var isStandalone =
        window.navigator.standalone === true ||
        window.matchMedia("(display-mode: standalone)").matches;

    if (!isStandalone) return;

    document.addEventListener("DOMContentLoaded", function () {
        var btn = document.getElementById("pwa-back-btn");
        if (!btn) return;

        btn.classList.remove("d-none");

        btn.addEventListener("click", function () {
            if (window.history.length > 1) {
                window.history.back();
            } else {
                window.location.href = "/web#action=point_of_sale.action_pos_pos_form";
            }
        });
    });
}());
