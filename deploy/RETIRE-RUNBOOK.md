# kg7ajm.com transition runbook

Status: **Phase 0 is installed and verified (2026-09-11).** kg7ajm.com serves the
holding page from copper01 with a valid certificate, DNS was not touched, and the domain
is out of rptdir.com's config entirely. Phase 1 runs when the new project is ready; Phase
2 only if that project hosts somewhere other than copper01.

Rollback points on the box:
`/root/rptdir.com.nginx.bak-20260911-223537`,
`/etc/nginx/backups/rptdir.com.pre-kg7ajm-park-20260911`,
`/root/letsencrypt-kg7ajm-2026-09-11.tgz` (cert, untouched, backed up anyway),
`/root/kg7ajm-rptdir-decouple.py` (the guarded edit script).

## 0. What we are doing

kg7ajm.com is being released from the repeater directory so it can be repurposed.
The directory itself already moved on 2026-08-27: every canonical URL the app knows
is `rptdir.com` (client canonical link, `seo.ts` CANONICAL_ROOT, sitemap base, the
`APP_URL` fallbacks). What is left on copper01 is the redirect, a PWA kill switch,
and a certificate.

We are NOT cutting the domain loose today. We are parking it:

| Phase | What happens | Cert | Kill switch | Deep links |
|---|---|---|---|---|
| **0 (done 2026-09-11)** | kg7ajm.com serves the hub page from copper01 | kept, keeps renewing | left in place, unused and free | replaced by the hub: no redirects |
| **1 (blog time)** | add the blog: a `blog.kg7ajm.com` vhost, or a `/blog` location in this file | kept | drop whenever | none exist to keep |
| **2 (only if the domain hosts elsewhere)** | DNS moves off copper01, then teardown + certbot delete | deleted | removed | gone |

Why not skip Phase 0: browsers that have visited kg7ajm.com since roughly March 2026
have HSTS pinned for the host (`max-age=15552000`, no `includeSubDomains`, not in the
preload list). A pinned hostname must answer with valid HTTPS or the visitor sees a
certificate error with no way through. Parking it on copper01 keeps a real cert in
front of the name, so the handover is a config swap instead of a DNS migration under
time pressure.

## 1. Facts pinned at draft time (2026-09-11)

| Thing | Value |
|---|---|
| Live nginx config, BEFORE Phase 0 | 118 lines / 7344 bytes, sha256 `a130b67aa455fd1026fec3dff40e0ce045d9a0eb79ae9dfa9eb8013620efc143` (what the decouple guard pins and what the backups hold) |
| Live nginx config, AFTER Phase 0 | 81 lines / 5505 bytes, sha256 `2d14b635fd35fcf8c769c1dc9b22f13b2591af3d62241c43b3c1dc960a6c770a` |
| kg7ajm config, after Phase 0 | `/etc/nginx/sites-enabled/kg7ajm.com` -> `sites-available/kg7ajm.com` |
| kg7ajm 443 block, before Phase 0 | lines 76 to 111 of the rptdir.com file |
| kg7ajm in rptdir port-80 block, before | line 116 (`server_name`) |
| Cert | `/etc/letsencrypt/live/kg7ajm.com`, expires Nov 19 2026, certbot 2.9.0 |
| Retire asset | `/var/www/kg7ajm-retire/sw.js`, 6340 bytes, 2026-08-28 |
| Namecheap records | `A @ -> 143.110.133.103` (TTL 300), `CNAME www -> kg7ajm.com` (TTL 300), `TXT _dmarc "v=DMARC1; p=none;"`. No MX, no apex SPF, no other hostnames. |
| Registrar | Namecheap, NS `dns1/dns2.registrar-servers.com`, expires 2027-09-17 |

Two things this runbook relies on:

1. **The nginx config is NOT in the repo and NOT deployed by CI.** It lives only at
   `/etc/nginx/sites-enabled/`. This is a manual prod edit. The GitHub Actions deploy
   workflow rsyncs `client/`, `server/`, `deploy/` and never touches nginx.
   (Side effect worth knowing: the holding page and site file live under `deploy/`, so
   committing them fires `deploy-copper01.yml`, which rebuilds and restarts the app.
   Harmless, but batch it with other work rather than fire it alone.)
2. **A record TTL is 300s**, so if and when the DNS does move, it settles in ~5 minutes.

## 2. Phase 0: park the domain on copper01

### 2.0 Artifacts added by this phase

| File | Goes to | Purpose |
|---|---|---|
| `deploy/kg7ajm-hub/index.html` | `/var/www/kg7ajm.com/index.html` | the hub page (one self-contained file) |
| `deploy/kg7ajm-hub/favicon.svg` | `/var/www/kg7ajm.com/favicon.svg` | signal-mark icon |
| `deploy/kg7ajm-hub/robots.txt` | `/var/www/kg7ajm.com/robots.txt` | crawler policy (currently allow all) |
| `deploy/kg7ajm-hub/kg7ajm.com.nginx` | `/etc/nginx/sites-available/kg7ajm.com` + symlink in `sites-enabled/` | the self-contained kg7ajm site |
| `deploy/kg7ajm-retire/sw.js` | `/var/www/kg7ajm-retire/sw.js` (already there) | PWA kill switch, still served |
| guarded script below | `/root/kg7ajm-rptdir-decouple.py` | strips the kg7ajm blocks out of rptdir.com's file |

The kg7ajm config moves out of the rptdir.com file into its own file, matching the
per-domain convention the rest of the box already uses (`copperimg`,
`hwtracker.live`, `shackboard.com`). That is what makes Phase 1 a one-file change.
It has to happen in the same step as the new file landing: duplicate `server_name`
on one listener is a hard nginx warning and one of the two blocks gets silently
ignored.

### 2.1 Pre-flight

```bash
ssh root@copper01
cd /etc/nginx

# 2.1a confirm the config has not changed since this runbook was written
sha256sum sites-enabled/rptdir.com
# pre-Phase-0 file must print a130b67aa455fd1026fec3dff40e0ce045d9a0eb79ae9dfa9eb8013620efc143
# Phase 0 is ALREADY APPLIED, so today it prints the post-Phase-0 hash (2d14b635...) and
# the decouple script answers "Already decoupled". Both are expected, not failures: the
# pin exists to stop a re-run writing into a config that changed underneath it.

# 2.1b back up the config, following the existing house convention
cp sites-enabled/rptdir.com /root/rptdir.com.nginx.bak-$(date +%Y%m%d-%H%M%S)
cp sites-enabled/rptdir.com /etc/nginx/backups/rptdir.com.pre-kg7ajm-park-$(date +%Y%m%d)

# 2.1c back up the cert too. Phase 0 KEEPS the cert, but a rollback that has to
#      re-issue is the expensive kind, and this tar is cheap.
tar czf /root/letsencrypt-kg7ajm-$(date +%F).tgz \
    -C /etc/letsencrypt live/kg7ajm.com archive/kg7ajm.com renewal/kg7ajm.com.conf

# 2.1d record current behaviour to compare against
curl -s -o /dev/null -w 'apex: %{http_code} -> %{redirect_url}\n' https://kg7ajm.com/
curl -s -o /dev/null -w 'deep: %{http_code} -> %{redirect_url}\n' 'https://kg7ajm.com/?state=az&band=2m'
curl -s -o /dev/null -w 'sw.js: %{http_code}\n' https://kg7ajm.com/sw.js
curl -s https://rptdir.com/build-id.txt; echo
```

### 2.2 Install

```bash
# 2.2a the hub page and its two static files
mkdir -p /var/www/kg7ajm.com
scp deploy/kg7ajm-hub/index.html   root@copper01:/var/www/kg7ajm.com/index.html
scp deploy/kg7ajm-hub/favicon.svg  root@copper01:/var/www/kg7ajm.com/favicon.svg
scp deploy/kg7ajm-hub/robots.txt   root@copper01:/var/www/kg7ajm.com/robots.txt
chown -R www-data:www-data /var/www/kg7ajm.com && chmod 644 /var/www/kg7ajm.com/*

# 2.2b the new site file + symlink (do not reload yet)
scp deploy/kg7ajm-hub/kg7ajm.com.nginx root@copper01:/etc/nginx/sites-available/kg7ajm.com
ln -s /etc/nginx/sites-available/kg7ajm.com /etc/nginx/sites-enabled/kg7ajm.com

# 2.2c decouple rptdir.com's file (guarded script, dry run first)
#      On copper01 this has to be off the port-80 listener too, or nginx warns
#      about the duplicate server_name and ignores one block.
python3 /root/kg7ajm-rptdir-decouple.py           # read the diff
python3 /root/kg7ajm-rptdir-decouple.py --apply   # only if it looks right

# 2.2d test and reload. nginx -t runs first, so a syntax error never takes
#      the live service down.
nginx -t && systemctl reload nginx
```

#### The guarded script

Refuses to write if the file's hash is not the one this runbook was built against,
knows when the work is already done, and asserts its own post-conditions.

```bash
cat > /root/kg7ajm-rptdir-decouple.py <<'PY'
#!/usr/bin/env python3
"""Remove the kg7ajm.com server blocks from rptdir.com's nginx file.

The domain now has its own file (sites-available/kg7ajm.com), so rptdir.com must
stop claiming those server_names or nginx warns and ignores one of the blocks.

Dry run by default. Writes only with --apply, and only if the input file still
matches the sha256 this runbook was written against.
"""
import difflib
import hashlib
import pathlib
import sys

CONF = pathlib.Path('/etc/nginx/sites-enabled/rptdir.com')
EXPECTED_SHA = 'a130b67aa455fd1026fec3dff40e0ce045d9a0eb79ae9dfa9eb8013620efc143'
OLD_COMMENT = '# kg7ajm.com redirects here with a 301 preserving path + query.\n'
NEW_COMMENT = '# kg7ajm.com is served by sites-enabled/kg7ajm.com (holding page) since 2026-09.\n'
OLD_PORT80 = '    server_name rptdir.com www.rptdir.com kg7ajm.com www.kg7ajm.com;\n'
NEW_PORT80 = '    server_name rptdir.com www.rptdir.com;\n'

raw = CONF.read_bytes()
text = raw.decode()

# Idempotency first: if the decoupled state is already in place, say so instead of
# tripping the hash guard below (which would print a misleading "config changed").
if 'server_name kg7ajm' not in text \
        and 'letsencrypt/live/kg7ajm.com' not in text \
        and '/var/www/kg7ajm-retire' not in text:
    print(f'Already decoupled: {CONF} has no kg7ajm server_name or cert reference.')
    sys.exit(0)

digest = hashlib.sha256(raw).hexdigest()
if digest != EXPECTED_SHA:
    sys.exit(f'ABORT: {CONF} sha256 is {digest}, expected {EXPECTED_SHA}. '
             'The live config changed; re-derive the hunk before applying.')

lines = text.splitlines(keepends=True)


def find(prefix):
    hits = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    if len(hits) != 1:
        sys.exit(f'ABORT: expected exactly 1 line starting with {prefix!r}, found {len(hits)}')
    return hits[0]


# 1. drop the whole 443 block, from its comment through the blank line before Port 80
start = find('# Legacy kg7ajm.com -> rptdir.com')
end = find('# Port 80: everything redirects')
del lines[start:end]

out = ''.join(lines)

# 2. narrow the port-80 server_name list (the new file owns kg7ajm.com there now)
if OLD_PORT80 not in out:
    sys.exit('ABORT: port-80 server_name line not found verbatim')
out = out.replace(OLD_PORT80, NEW_PORT80)

# 3. refresh the stale header comment
if OLD_COMMENT in out:
    out = out.replace(OLD_COMMENT, NEW_COMMENT)

# 4. post-conditions: nothing functional may still reference the moved host
for bad in ('server_name kg7ajm', 'server_name rptdir.com www.rptdir.com kg7ajm',
            'letsencrypt/live/kg7ajm.com', '/var/www/kg7ajm-retire'):
    if bad in out:
        sys.exit(f'ABORT: post-condition failed, {bad!r} still present')

if out == text:
    sys.exit('Nothing to do (already decoupled).')

print(''.join(difflib.unified_diff(
    text.splitlines(keepends=True), out.splitlines(keepends=True),
    fromfile=str(CONF), tofile=str(CONF) + ' (proposed)')))

if '--apply' not in sys.argv:
    print('\nDRY RUN. Re-run with --apply to write the file.')
else:
    CONF.write_text(out)
    print('\nWROTE', CONF)
PY
```

#### What the apply produces

```diff
@@ -1,5 +1,5 @@
 # rptdir.com - Repeater Directory (primary domain, since 2026-08-27)
-# kg7ajm.com redirects here with a 301 preserving path + query.
+# kg7ajm.com is served by sites-enabled/kg7ajm.com (holding page) since 2026-09.
 # Security headers shared across the server block. NOTE: nginx only inherits
 # server-level add_header into locations that don't define their own, so the
 # sw.js and assets locations below repeat these explicitly.
@@ -73,46 +73,9 @@
     return 301 https://rptdir.com$request_uri;
 }
 
-# Legacy kg7ajm.com -> rptdir.com (301, path + query preserved)
-server {
-    server_name kg7ajm.com www.kg7ajm.com;
-    listen 443 ssl;
-    ssl_certificate /etc/letsencrypt/live/kg7ajm.com/fullchain.pem;
-    ... (36-line block, including the /sw.js kill switch) ...
-}
-
 # Port 80: everything redirects to the canonical https://rptdir.com
 server {
     listen 80;
-    server_name rptdir.com www.rptdir.com kg7ajm.com www.kg7ajm.com;
+    server_name rptdir.com www.rptdir.com;
     return 301 https://rptdir.com$request_uri;
 }
```

The file goes from 118 lines / 7344 bytes to 81 lines / 5491 bytes. The kill switch
`location = /sw.js` is not lost: it moves into `kg7ajm.com.nginx` verbatim, pointing
at the same `/var/www/kg7ajm-retire/sw.js`.

### 2.3 Verify

Expected results, in one table so a failure is obvious:

| Request | Expect |
|---|---|
| `https://kg7ajm.com/` | `200`, hub page, valid cert, strict CSP, HSTS |
| `https://www.kg7ajm.com/` | `200`, same page |
| `http://kg7ajm.com/` | `301` to `https://kg7ajm.com/` (itself, never to rptdir.com) |
| `https://kg7ajm.com/index.html` | `200`, same page and headers |
| `https://kg7ajm.com/favicon.svg` | `200`, `image/svg+xml` |
| `https://kg7ajm.com/robots.txt` | `200`, `text/plain`, `Allow: /` |
| `https://kg7ajm.com/sw.js` | `200`, `application/javascript`, 6340 bytes |
| `https://kg7ajm.com/favicon.ico` | `204` |
| `https://kg7ajm.com/?state=az&band=2m` | `200`, the hub |
| `https://kg7ajm.com/some/old/page?q=1` | `200`, the hub (fallback) |

The last two rows changed on 2026-09-11: the domain no longer redirects anywhere, so old
deep links land on the hub, which links out to rptdir.com. While the page was a holding
page the config needed an `if ($args != "")` guard, because nginx matches a location
against the URI without the query string and a naive `location = /` swallowed every
query-form deep link. That guard is gone with the redirects; the pitfall is worth
remembering for any future landing page on this box (see the `rpt-app-dev` skill,
`references/nginx-config-change-verification.md`).

```bash
B=https://kg7ajm.com
for u in "/" "/index.html" "/sw.js" "/favicon.ico" "/?state=az&band=2m" \
         "/?view=map" "/?list=abc" "/?ticket=xyz" "/some/old/page?q=1"; do
  printf '%-32s ' "$u"
  curl -sS -o /dev/null -w 'code=%{http_code} type=%{content_type} -> %{redirect_url}\n' "$B$u"
done
curl -sSI $B/ | grep -iE '^(HTTP|content-security-policy|cache-control|strict-transport)' | tr -d '\r'
curl -sS $B/ | grep -o '<h1>[^<]*</h1>'
curl -sSI http://kg7ajm.com/ | head -1 ; curl -sS -o /dev/null -w '%{redirect_url}\n' http://kg7ajm.com/

# rptdir must be untouched
curl -s https://rptdir.com/api/health
curl -s https://rptdir.com/build-id.txt; echo
curl -s https://rptdir.com/ | grep -o 'index-[A-Za-z0-9_-]*\.css'   # matches local client/dist
systemctl is-active nginx rpt
nginx -T | grep kg7ajm    # expect only the two doc comments, no server_name
```

Then in the browser: load https://kg7ajm.com/ and confirm the page renders, and follow
one deep link to confirm it lands on rptdir.com with its state intact.

### 2.4 Rehearse on a throwaway instance first (recommended)

Installing straight into the live prefix means a mistake is only visible after a
reload. The config can be exercised first on a spare port, against real files, with
zero impact on the live service. This is how the query-string guard above was caught.

```bash
# build a proposed tree and a throwaway listener
ssh root@copper01
mkdir -p /tmp/ngxpre/sites-enabled && cp -L /etc/nginx/sites-enabled/* /tmp/ngxpre/sites-enabled/
cp /etc/nginx/nginx.conf /tmp/ngxpre/nginx.conf
sed -i 's#include /etc/nginx/sites-enabled/\*;#include /tmp/ngxpre/sites-enabled/*;#' /tmp/ngxpre/nginx.conf
# relative includes (mime.types, snippets/*) resolve against the prefix, so mirror
# every other top-level entry into it
cd /tmp/ngxpre && for f in /etc/nginx/*; do b=$(basename "$f"); \
  case "$b" in sites-enabled|nginx.conf) continue;; esac; ln -sfn "$f" "$b"; done
# apply the decouple to the copy and drop the new site file in, then test
python3 decouple.py --apply          # with CONF pointed at the copy
nginx -t -p /tmp/ngxpre -c /tmp/ngxpre/nginx.conf
```

For behaviour rather than syntax, run a second, minimal instance: a two-line
`nginx.conf` with `events{}` + `http{}` that includes a copy of the kg7ajm block with
`listen 443 ssl` rewritten to a free port (18443), `root` pointed at a temp copy of the
page, and the log lines redirected to `/tmp`. Start it with
`nginx -p /tmp/ngxserve -c /tmp/ngxserve/nginx.conf`, curl it on 127.0.0.1, then
`nginx -p /tmp/ngxserve -c /tmp/ngxserve/nginx.conf -s stop`. Keep the file's own
port-80 block out of that copy or it collides with the live listener.

### 2.5 Rollback

| Stage | Rollback |
|---|---|
| config swapped | `cp /root/rptdir.com.nginx.bak-<ts> /etc/nginx/sites-enabled/rptdir.com && rm /etc/nginx/sites-enabled/kg7ajm.com && nginx -t && systemctl reload nginx` |
| hub page files | delete `/var/www/kg7ajm.com`; nothing else references it |
| cert | untouched, since the hub needs it; the tar covers the Phase 2 delete |

## 3. Phase 1: adding the blog

The hub already carries a Blog card, deliberately unlinked. Publishing it is a one-line
change plus whatever the blog software needs. Two shapes, and the choice mostly follows
from how the blog is built.

**blog.kg7ajm.com (subdomain)**: the right shape for a self-hosted blog (Ghost,
WordPress, or a static generator with its own docroot). Needs all three of:

1. DNS at Namecheap: `CNAME blog -> kg7ajm.com` (records are cheap and the TTL is 300s).
2. A server block at `/etc/nginx/sites-available/blog.kg7ajm.com`, following the
   per-domain convention on this box. Do NOT add the name to `sites-enabled/kg7ajm.com`:
   the same `server_name` on one listener means nginx warns and silently ignores one
   block. `nginx -t && systemctl reload nginx` before asking for the certificate, since
   certbot's nginx authenticator needs a block to insert its challenge into.
3. `certbot --nginx -d blog.kg7ajm.com`. Cert and renewal are then automatic.

**kg7ajm.com/blog (path)**: no DNS, no certificate, no new vhost. One location block in
`sites-enabled/kg7ajm.com`, placed ABOVE the `location /` fallback (the fallback would
otherwise answer every path with the hub):

```nginx
location /blog/ {
    alias /var/www/kg7ajm.com/blog/;          # or proxy_pass http://127.0.0.1:<port>;
    try_files $uri $uri/ /blog/index.html =404;
}
```

Then either way:

- point the card at it: in `deploy/kg7ajm-hub/index.html`, turn the Blog `<span
  class="boxed">` into `<a href="...">`, drop the `Coming soon` chip, re-upload;
- `nginx -t && systemctl reload nginx`;
- verify with the loop in 2.3, with the blog URL added to the list;
- the hub's CSP needs no change. It governs the hub page only, and outbound links are
  not restricted by CSP.

## 4. Phase 2: only if the domain leaves copper01

Everything here assumes the blog or whatever comes next is hosted elsewhere, so nothing
needs copper01 to keep answering.

```bash
# 4a. Namecheap: change A @ to the new target. www is a CNAME to kg7ajm.com, so it
#     follows automatically. Verify the new host serves valid HTTPS on BOTH names
#     before the next step, because the HSTS pin is still live in visitor browsers.
dig @dns1.registrar-servers.com kg7ajm.com A +short   # new target
curl -sI https://kg7ajm.com/ | head -3
curl -sI https://www.kg7ajm.com/ | head -3

# 4b. once propagation is confirmed, remove the local blocks
rm /etc/nginx/sites-enabled/kg7ajm.com        # keep sites-available for the record
nginx -t && systemctl reload nginx

# 4c. delete the certificate LAST. Doing it while a live block still references it
#     leaves nginx unable to start after the next restart.
certbot delete --cert-name kg7ajm.com         # certbot 2.9.0 syntax, verified present
certbot certificates | grep -i kg7ajm         # expect no output
nginx -t && systemctl reload nginx

# 4d. drop the kill switch and the holding page
rm -rf /var/www/kg7ajm-retire /var/www/kg7ajm.com
```

**Ordering is load-bearing.** copper01 has no `default_server`, so a request for a
host with no matching server block falls through to the first 443 block in config load
order. Measured 2026-09-11 with an unknown Host header: it 301s to
`https://camp-israel.copperstatedesign.com/` (a WordPress site). Removing the kg7ajm
blocks while DNS still points here would bounce kg7ajm.com visitors to a client's
site. Park, verify, then remove.

## 5. The kill switch dies with the DNS, not with the config

While kg7ajm.com points at copper01, `location = /sw.js` still rescues any browser
holding the pre-cutover workbox worker. The moment DNS moves, requests never reach
this server and that rescue path is gone. It cannot be preserved on a repurposed
domain either: the worker redirects every navigation to rptdir.com, which would break
the new project.

Measured, so this is not guesswork:

- Pre-cutover the origin did ~19,500 requests/day.
- `/var/log/nginx/kg7ajm.com.access.log` has been 0 lines since 2026-08-28 (the old
  retire block declared no `access_log`, so its traffic went to the default log).
- Kill-switch `/sw.js` hits: 3 in the last two days, two of them Slack/Telegram
  link-expander bots. Roughly 1 to 2 real browsers per day still check in.
- Browsers that never revisit cannot be counted, and cannot be rescued either: the
  kill switch only reaches a browser when it loads a page at that origin.

**Phase 0 restores the measurement.** The new `sites-enabled/kg7ajm.com` declares its own
`access_log /var/log/nginx/kg7ajm.com.access.log`, so from 2026-09-11 that file records
again after being silent since 2026-08-28. Before deciding the kill switch has outlived its
purpose, count `/sw.js` hits there (and check the User-Agent: link-expander bots fetch it
too).

That last point is why Phase 0 is worth doing: it costs one static file and no DNS
work, and it keeps the rescue path alive for free while the new project is built.

## 6. Appendix: retire immediately, without a holding page

Only relevant if the domain must leave copper01 right now and the new host already
serves valid HTTPS. Then Phase 0 and Phase 2 collapse into one: run the decrypt script
(2.2c), delete the kg7ajm blocks, `certbot delete --cert-name kg7ajm.com`, remove
`/var/www/kg7ajm-retire`, and move the DNS. The diff is the same one shown in 2.2,
minus the new site file.
