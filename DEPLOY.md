# Deploying kg7ajm.com

This repo owns the whole domain. `kg7ajm.com` serves a static hub at `/`, the Jekyll
video blog at `/blog`, and the pre-cutover service worker at `/sw.js`. Nothing here
touches the repeater app or any other site on copper01: the pipeline can only write
`/var/www/kg7ajm.com`, `/var/www/kg7ajm-retire`, and the `kg7ajm.com` vhost.

## Layout

| Path | What it is | Ends up at |
|---|---|---|
| `hub/index.html`, `hub/favicon.svg`, `hub/robots.txt` | the domain root: a static hub linking to rptdir.com, shackboard.com and the blog | `/var/www/kg7ajm.com/` |
| `_posts/`, `_layouts/`, `index.html`, `index.css`, `main.js` | the Jekyll blog (this repo's root is the Jekyll source) | built to `_site/`, then `/var/www/kg7ajm.com/blog/` |
| `scripts/fetch_youtube.rb` | regenerates `_posts/` from the YouTube playlist: one post per video, ordered by each video's real upload date | not deployed |
| `deploy/kg7ajm.com.nginx` | the vhost of record for kg7ajm.com | `/etc/nginx/sites-available/kg7ajm.com` |
| `deploy/sw.js` | the PWA kill switch, served at `/sw.js` | `/var/www/kg7ajm-retire/sw.js` |
| `deploy/remote-install.sh` | runs on copper01: installs the static files and the vhost, gated on `nginx -t` | not deployed |

Wider operations notes for the box, including how the domain was released from the
repeater directory and the teardown steps, live in the private `rpt` repo at
`deploy/kg7ajm-retire/RETIRE-RUNBOOK.md`.

`hub/` and `deploy/` are excluded from the Jekyll build in `_config.yml`, so they never
land in `_site`.

## Automatic deploy

`.github/workflows/deploy-kg7ajm-com.yml` runs on every push to `main`, once a day at
09:00 UTC (so new playlist videos appear on their own), and on manual dispatch. It:

1. runs `scripts/fetch_youtube.rb` so the post list matches the playlist right now,
2. builds the blog,
3. connects to the tailnet, rsyncs the built blog to `/var/www/kg7ajm.com/blog/`,
   staging `hub/`, the vhost and the installer in `/tmp/kg7ajm-stage`,
4. runs `deploy/remote-install.sh`, which installs the static files and the vhost and
   reloads nginx **only if the vhost changed and `nginx -t` accepts it**,
5. smoke tests `/`, `/blog/` and `/blog/feed.xml` over the public URL and fails the run
   if any of them is not 200, or if the hub page has lost its heading.

Until the secrets exist the run stays green and skips the deploy with a notice, so a
half-configured repo cannot produce red builds.

### Secrets this repo needs

| Secret | Value |
|---|---|
| `TAILSCALE_AUTHKEY` | a tailnet auth key that is **Reusable + Ephemeral** and tagged `tag:ci`. A single-use key burns on the first run and every later run fails with `invalid key` while the step still reports success. |
| `SSH_KEY` | private key whose public half is in `root`'s `authorized_keys` on copper01 |
| `SSH_HOST` | copper01's **tailnet** address, not its public IP (SSH is tailnet-only) |
| `SSH_USER` | `root` (the installer writes to `/var/www` and `/etc/nginx`) |

Add them under Settings, Secrets and variables, Actions. Then run the workflow once with
Run workflow to prove the whole path end to end.

## Working on the blog locally

```bash
bundle install
ruby scripts/fetch_youtube.rb          # refresh _posts from the playlist (optional)
bundle exec jekyll serve               # http://localhost:4000/blog/
```

Because `baseurl` is `/blog`, the local URL includes `/blog/`. Previewing at the root
will look broken, that is expected. If you add a video to the playlist, re-run the
scraper and commit the regenerated `_posts`; the daily deploy refreshes them in CI
anyway, the committed copy is just a snapshot for local builds.

## Doing it by hand

```bash
# from this repo, after a build
rsync -az --delete _site/ root@<tailnet-ip>:/var/www/kg7ajm.com/blog/
rsync -az hub/ root@<tailnet-ip>:/tmp/kg7ajm-stage/hub/
rsync -az deploy/kg7ajm.com.nginx deploy/sw.js deploy/remote-install.sh \
      root@<tailnet-ip>:/tmp/kg7ajm-stage/deploy/
ssh root@<tailnet-ip> 'bash /tmp/kg7ajm-stage/deploy/remote-install.sh /tmp/kg7ajm-stage'

# see what it would do, without writing anything
ssh root@<tailnet-ip> 'bash /tmp/kg7ajm-stage/deploy/remote-install.sh --dry-run /tmp/kg7ajm-stage'
```

## Safety

- The vhost is installed only if `nginx -t` accepts it. On failure the previous vhost is
  restored from `/root/kg7ajm.com.nginx.bak-<timestamp>` and nginx is never reloaded, so
  a bad config cannot take the other sites on copper01 down with it. Backups also land in
  `/etc/nginx/backups/`.
- The blog rsync targets `/var/www/kg7ajm.com/blog/` only, so `--delete` cannot reach the
  hub page or anything else in the docroot.
- The nightly backup job on the server bundles the docroot and the nginx configs
  offsite, so the static site and the vhost survive even without GitHub.
