// The UI calls trader-app same-origin under /api (the GKE Ingress, or a local reverse proxy, strips the prefix).
// Overrides, highest first: window.AXON_TRADER_CONFIG.apiRoot from public/config.js (replaced at runtime by a mounted
// file, e.g. for local development without a proxy), then REACT_APP_API_ROOT at build time (e.g. for `npm start`).
export const DEFAULT_API_ROOT = '/api';

const runtimeApiRoot = () => {
  const config = typeof window !== 'undefined' ? window.AXON_TRADER_CONFIG : undefined;
  return config && typeof config.apiRoot === 'string' ? config.apiRoot : undefined;
};

export const ApiConfig = () => {
  const runtime = runtimeApiRoot();
  let apiRoot;
  if (runtime !== undefined) {
    apiRoot = runtime;
  } else if (process.env.REACT_APP_API_ROOT !== undefined) {
    apiRoot = process.env.REACT_APP_API_ROOT;
  } else {
    apiRoot = DEFAULT_API_ROOT;
  }
  return apiRoot.replace(/\/+$/, '');
};
