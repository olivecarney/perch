export const logos = ['server', 'jellyfin', 'proxmox', 'home-assistant', 'pi-hole', 'immich', 'truenas', 'portainer', 'grafana'];
export const logoNames = ['Server', 'Jellyfin', 'Proxmox', 'Home Assistant', 'Pi-hole', 'Immich', 'TrueNAS', 'Portainer', 'Grafana'];
export const localLogo = name => `/icons/${name}.svg?v=1`;

export function logoCandidates(app) {
  if (logos.includes(app.logo)) return [localLogo(app.logo)];
  if (app.logo && app.logo !== 'auto') return [app.logo];
  const url = new URL(app.address);
  const base = new URL(url.pathname.endsWith('/') ? url.pathname : `${url.pathname}/`, url.origin);
  return [...new Set([
    new URL('favicon.ico', base).href,
    new URL('/favicon.ico', url.origin).href,
    new URL('/favicon.svg', url.origin).href,
    new URL('/apple-touch-icon.png', url.origin).href,
  ])];
}

export function fallbackLogo(app) {
  const label = `${app.name} ${app.address}`.toLowerCase().replace(/[^a-z0-9]/g, '');
  const name = logos.slice(1).find(name => label.includes(name.replace(/-/g, '')));
  return localLogo(name || 'server');
}

// Only visible images are resolved. Results are reused across edits and reordering.
const cache = new Map();
function probe(source) {
  return new Promise(resolve => {
    const image = new Image();
    image.referrerPolicy = 'no-referrer';
    const finish = result => {
      clearTimeout(timer);
      image.onload = image.onerror = null;
      if (!result) image.removeAttribute('src');
      resolve(result);
    };
    const timer = setTimeout(() => finish(null), 2200);
    image.onload = () => finish(image.naturalWidth > 0 ? source : null);
    image.onerror = () => finish(null);
    image.src = source;
  });
}
export function resolveLogo(app) {
  const key = `${app.address}|${app.logo}|${app.name}`;
  if (!cache.has(key)) {
    if (cache.size > 512) cache.clear();
    cache.set(key, (async () => {
      for (const source of logoCandidates(app)) {
        const found = await probe(source);
        if (found) return found;
      }
      return fallbackLogo(app);
    })());
  }
  return cache.get(key);
}
