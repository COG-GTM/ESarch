import { ApiConfig, DEFAULT_API_ROOT } from './config';

describe('ApiConfig', () => {
  const originalEnv = process.env.REACT_APP_API_ROOT;

  afterEach(() => {
    delete window.AXON_TRADER_CONFIG;
    if (originalEnv === undefined) {
      delete process.env.REACT_APP_API_ROOT;
    } else {
      process.env.REACT_APP_API_ROOT = originalEnv;
    }
  });

  it('calls the API same-origin under /api by default', () => {
    delete process.env.REACT_APP_API_ROOT;
    expect(DEFAULT_API_ROOT).toEqual('/api');
    expect(ApiConfig()).toEqual('/api');
  });

  it('has no cfapps.io host map left', () => {
    delete process.env.REACT_APP_API_ROOT;
    expect(ApiConfig()).not.toMatch(/cfapps\.io/);
  });

  it('uses REACT_APP_API_ROOT from the build when there is no runtime override', () => {
    process.env.REACT_APP_API_ROOT = 'http://localhost:8080/';
    expect(ApiConfig()).toEqual('http://localhost:8080');
  });

  it('prefers the runtime override from a mounted config.js', () => {
    process.env.REACT_APP_API_ROOT = 'http://localhost:8080';
    window.AXON_TRADER_CONFIG = { apiRoot: 'http://127.0.0.1:9090/' };
    expect(ApiConfig()).toEqual('http://127.0.0.1:9090');
  });

  it('accepts an empty runtime override (root-relative /query and /command)', () => {
    window.AXON_TRADER_CONFIG = { apiRoot: '' };
    expect(ApiConfig()).toEqual('');
  });

  it('ignores a runtime config without apiRoot', () => {
    delete process.env.REACT_APP_API_ROOT;
    window.AXON_TRADER_CONFIG = {};
    expect(ApiConfig()).toEqual('/api');
  });
});
