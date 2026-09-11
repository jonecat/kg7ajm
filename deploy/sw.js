/*
 * kg7ajm.com retirement service worker ("kill switch").
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * kg7ajm.com 301-redirects to rptdir.com at nginx, but any browser that loaded
 * the app from kg7ajm.com before the 2026-08-27 cutover still has a workbox
 * service worker registered at that origin. That worker answers navigations
 * from its precache, so the request never reaches nginx and the 301 never
 * fires: the visitor sits on kg7ajm.com running a pre-cutover bundle.
 *
 * It cannot self-heal either. The browser's periodic update check fetches
 * https://kg7ajm.com/sw.js, gets the 301, and fails with:
 *
 *   TypeError: Failed to update a ServiceWorker for scope
 *   ('https://kg7ajm.com/') with script ('https://kg7ajm.com/sw.js'):
 *   The script resource is behind a redirect, which is disallowed.
 *
 * So the old worker is immortal. The fix is to SERVE this script at
 * https://kg7ajm.com/sw.js (200, JS content type, Cache-Control: no-store)
 * instead of redirecting it. The next visit's update check then succeeds, this
 * worker installs, wipes the old caches, moves open tabs to rptdir.com, and
 * unregisters itself. After that the origin has no worker and plain nginx
 * 301s handle everything.
 *
 * Deployed to copper01 at /var/www/kg7ajm-retire/sw.js and served by an exact
 * `location = /sw.js` block inside the kg7ajm.com server block in
 * /etc/nginx/sites-enabled/rptdir.com. Keep serving it for as long as stale
 * clients may return (months, not days).
 *
 * This file is NOT part of the client build. Do not add it to client/public.
 */

var CANONICAL_ORIGIN = 'https://rptdir.com';

function canonicalUrlFor(rawUrl) {
  try {
    var u = new URL(rawUrl);
    return CANONICAL_ORIGIN + u.pathname + u.search + u.hash;
  } catch (err) {
    return CANONICAL_ORIGIN + '/';
  }
}

// Resolves on success, error, OR blocked: a blocked delete still often lands
// once the last tab holding the connection unloads, and either way this worker
// must not hang waiting for it.
function deleteDatabase(name) {
  return new Promise(function (resolve) {
    try {
      var req = indexedDB.deleteDatabase(name);
      req.onsuccess = function () { resolve(); };
      req.onerror = function () { resolve(); };
      req.onblocked = function () { resolve(); };
    } catch (err) {
      resolve();
    }
  });
}

async function deleteAllDatabases() {
  var names = ['rpt_offline_v1'];
  try {
    if (indexedDB.databases) {
      var listed = await indexedDB.databases();
      for (var i = 0; i < listed.length; i += 1) {
        var name = listed[i] && listed[i].name;
        if (name && names.indexOf(name) === -1) names.push(name);
      }
    }
  } catch (err) {
    // Fall back to the known name.
  }
  await Promise.all(names.map(deleteDatabase));
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise(function (resolve) {
      setTimeout(resolve, ms);
    }),
  ]);
}

// Activate immediately instead of waiting for every old tab to close.
self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    (async function () {
      // 1. Drop every Cache Storage bucket the retired app left behind
      //    (workbox precache, api-meta-cache, carto-basemap-tiles).
      try {
        var keys = await caches.keys();
        await Promise.all(
          keys.map(function (key) {
            return caches.delete(key);
          })
        );
      } catch (err) {
        // Keep going: unregistering matters more than a clean cache.
      }

      // 2. Take control of the tabs the retired worker was serving.
      try {
        await self.clients.claim();
      } catch (err) {}

      // 3. Move those tabs to the canonical origin, preserving the path.
      //    WindowClient.navigate() may refuse a cross-origin target, so fall
      //    back to a same-origin navigate and let the fetch handler below
      //    answer it with the cross-origin redirect.
      try {
        var windows = await self.clients.matchAll({ type: 'window' });
        for (var i = 0; i < windows.length; i += 1) {
          var client = windows[i];
          try {
            await client.navigate(canonicalUrlFor(client.url));
          } catch (err) {
            try {
              await client.navigate(client.url);
            } catch (err2) {}
          }
        }
      } catch (err) {}

      // 4. Reclaim the offline repeater cache stranded at the dead origin
      //    (measured 12.1 MB of IndexedDB per affected browser). This runs
      //    AFTER the navigate above, because a tab still holding
      //    rpt_offline_v1 open makes deleteDatabase fire `blocked` and never
      //    finish, and BEFORE unregister, so waitUntil still keeps this worker
      //    alive. Every outcome resolves and a timeout caps the wait: the
      //    delete is hygiene, never a reason to stall the retirement.
      try {
        await withTimeout(deleteAllDatabases(), 4000);
      } catch (err) {}

      // 5. Remove this registration. Already-loaded tabs stay controlled until
      //    they unload, which is what lets the fetch handler finish the job.
      try {
        await self.registration.unregister();
      } catch (err) {}
    })()
  );
});

// Any navigation still routed through this worker goes to rptdir.com.
self.addEventListener('fetch', function (event) {
  var request = event.request;
  if (request.mode !== 'navigate') return;

  var target = canonicalUrlFor(request.url);
  event.respondWith(
    (function () {
      try {
        return Response.redirect(target, 302);
      } catch (err) {
        // Bulletproof fallback if a synthetic redirect is refused.
        var html =
          '<!doctype html><meta charset="utf-8">' +
          '<meta http-equiv="refresh" content="0;url=' +
          target +
          '">' +
          '<title>Moved to rptdir.com</title>' +
          '<script>location.replace(' +
          JSON.stringify(target) +
          ')</script>' +
          '<p>This site moved to <a href="' +
          target +
          '">rptdir.com</a>.</p>';
        return new Response(html, {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      }
    })()
  );
});
