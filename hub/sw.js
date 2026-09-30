/* Gesture Approve Hub —— service worker。
 *
 * 只做一件事：让主屏图标点开时**一定有东西出现**，哪怕 Mac 睡着了、Wi-Fi 换了。
 * 缓存的是外壳（HTML/图标），数据一律直通网络 —— 一个缓存过的会话列表比空白更糟，
 * 它会让你以为某个会话还在等你批准，而那可能是半天前的事。
 */
const VERSION = 'ga-hub-v1';
const SHELL = ['/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  // 装好立刻接管，用户不必把 app 关掉再开才拿到新版本。
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

/** 数据端点：缓存这些只会撒谎，必须每次都问服务器。 */
function isData(url) {
  return /^\/(v2\/|sessions|session\/|pending|events|cloud\/|asr|reply|health|ga\/|config)/.test(url.pathname);
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;                 // POST（审批/回复/语音）永远直通
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (isData(url)) return;                          // 数据端点交给浏览器默认处理

  // 导航请求：先走网络（拿到的是注入了新 token 的页面），断网了才用缓存的壳。
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req)
        .then((res) => {
          // 页面按路径缓存，忽略 ?token= —— 否则换一次 token 就多一份缓存副本。
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(url.pathname, copy));
          return res;
        })
        .catch(() => caches.match(url.pathname).then((hit) => hit || caches.match('/')))
    );
    return;
  }

  // 静态资源（图标）：缓存优先，省一次往返。
  e.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
});
