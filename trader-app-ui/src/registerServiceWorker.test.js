import { unregister } from './registerServiceWorker';

describe('unregister', () => {
  const originalServiceWorker = Object.getOwnPropertyDescriptor(window.navigator, 'serviceWorker');

  afterEach(() => {
    if (originalServiceWorker) {
      Object.defineProperty(window.navigator, 'serviceWorker', originalServiceWorker);
    } else {
      delete window.navigator.serviceWorker;
    }
  });

  it("unregisters the app's registration even without an active worker, and leaves other scopes alone", async () => {
    const appScope = new URL(`${process.env.PUBLIC_URL}/`, window.location.href).href;
    const installing = { scope: appScope, active: null, unregister: jest.fn(() => Promise.resolve(true)) };
    const otherApp = {
      scope: new URL('/reports/', window.location.href).href,
      active: {},
      unregister: jest.fn(() => Promise.resolve(true)),
    };
    Object.defineProperty(window.navigator, 'serviceWorker', {
      configurable: true,
      value: { getRegistrations: () => Promise.resolve([installing, otherApp]) },
    });

    await unregister();

    expect(installing.unregister).toHaveBeenCalledTimes(1);
    expect(otherApp.unregister).not.toHaveBeenCalled();
  });

  it('does nothing when service workers are not supported', async () => {
    delete window.navigator.serviceWorker;
    await expect(unregister()).resolves.toBeUndefined();
  });
});
