export const HostURLsMapping = {
  'localhost': process.env.REACT_APP_API_ROOT || 'http://localhost:8080',
  'esrefarch-demo-trader-ui.cfapps.io': 'https://esrefarch-demo-trader-app.cfapps.io',
  'axontrader.cfapps.io': 'https://esrefarch-demo-trader-app.cfapps.io',
};
export const ApiConfig = () => {
  const hostname = window.location.hostname;
  const apiURL = HostURLsMapping[hostname];
  return apiURL || '';
};
