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

  it('unregisters every registration, including ones without an active worker', async () => {
    const installing = { active: null, unregister: jest.fn(() => Promise.resolve(true)) };
    const active = { active: {}, unregister: jest.fn(() => Promise.resolve(true)) };
    Object.defineProperty(window.navigator, 'serviceWorker', {
      configurable: true,
      value: { getRegistrations: () => Promise.resolve([installing, active]) },
    });

    await unregister();

    expect(installing.unregister).toHaveBeenCalledTimes(1);
    expect(active.unregister).toHaveBeenCalledTimes(1);
  });

  it('does nothing when service workers are not supported', async () => {
    delete window.navigator.serviceWorker;
    await expect(unregister()).resolves.toBeUndefined();
  });
});
