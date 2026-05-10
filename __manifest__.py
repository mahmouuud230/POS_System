{
    'name': 'PWA POS iOS',
    'version': '18.0.1.0.0',
    'category': 'Point of Sale',
    'summary': 'PWA meta tags, iOS standalone mode, and QR/Barcode scanner for POS',
    'author': 'Odoo SaaS',
    'license': 'LGPL-3',
    'depends': ['point_of_sale', 'web'],
    'data': [
        'views/web_layout_inherit.xml',
    ],
    'assets': {
        'web.assets_common': [
            'pwa_pos_ios/static/src/js/pwa_service_worker_register.js',
        ],
        'point_of_sale.assets': [
            'pwa_pos_ios/static/src/js/qr_scanner_widget.js',
            'pwa_pos_ios/static/src/css/scanner.css',
        ],
    },
    'installable': True,
    'auto_install': False,
    'application': False,
}
