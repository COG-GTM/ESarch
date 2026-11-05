// Runtime configuration for the Axon Trader UI, loaded before the app bundle.
// The image ships this default; mount a replacement at /usr/share/nginx/html/config.js to override it, e.g.
//   window.AXON_TRADER_CONFIG = { apiRoot: 'http://localhost:8080' };
// Leave apiRoot unset to call trader-app same-origin under /api.
window.AXON_TRADER_CONFIG = window.AXON_TRADER_CONFIG || {};
