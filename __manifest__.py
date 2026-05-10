# -*- coding: utf-8 -*-
# File: odoo/addons/pwa_pos_ios/__manifest__.py
{
    'name': 'PWA POS – iOS Standalone & Scanner',
    'version': '18.0.1.0.0',
    'category': 'Point of Sale',
    'summary': 'Injects PWA meta-tags, iOS icons and QR/Barcode scanner for POS',
    'author': 'Your Company',
    'license': 'LGPL-3',
    'depends': ['point_of_sale', 'web'],
    'data': [
        'views/web_layout_inherit.xml',
    ],
    'assets': {
        # Loaded on every backend/PWA page
        'web.assets_common': [
            'pwa_pos_ios/static/src/js/pwa_service_worker_register.js',
        ],
        # Loaded only inside the POS session
        'point_of_sale.assets': [
            'pwa_pos_ios/static/src/js/qr_scanner_widget.js',
            'pwa_pos_ios/static/src/css/scanner.css',
        ],
    },
    'installable': True,
    'auto_install': False,
    'application': False,
}
