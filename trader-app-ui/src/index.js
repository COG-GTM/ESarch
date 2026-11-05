import React from 'react';
import ReactDOM from 'react-dom';
import './index.css';
import App from './containers/App';
import { unregister as unregisterServiceWorker } from './registerServiceWorker';

if (process.env.NODE_ENV !== 'production') {
  require('dotenv').load();
}

ReactDOM.render(<App />, document.getElementById('root'));
// No service worker: its cache-first precache would keep serving a stale /config.js after the mounted file changes.
// Unregistering also removes workers installed by earlier builds.
unregisterServiceWorker();
