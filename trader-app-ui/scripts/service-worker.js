// Replaces the precache worker that earlier builds registered. Browsers that still have it fetch this file on their
// next update check (nginx serves it with no-cache); it then deletes the precache, unregisters itself and reloads its
// pages so they stop getting a cached index.html and config.js.
self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', event => {
  event.waitUntil(
    caches
      .keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith('sw-precache-')).map(key => caches.delete(key))))
      .then(() => self.registration.unregister())
      .then(() => self.clients.matchAll({ type: 'window' }))
      .then(clients => Promise.all(clients.map(client => client.navigate(client.url))))
  );
});
