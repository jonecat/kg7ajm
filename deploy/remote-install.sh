#!/bin/bash
# Installs the kg7ajm.com static site, blog ownership and vhost on copper01.
#
# Run by .github/workflows/deploy-kg7ajm-com.yml over SSH as root, and safe to run by
# hand. Idempotent: files that already match are left alone, and nginx is only reloaded
# when the vhost actually changed. A vhost that nginx -t rejects is restored from the
# backup and never reloaded, so a bad config cannot take the other sites on this box
# down with it.
#
# Usage:  remote-install.sh [--dry-run] [STAGE_DIR]
#   STAGE_DIR defaults to /tmp/kg7ajm-stage and must contain:
#     hub/index.html  hub/favicon.svg  hub/robots.txt
#     deploy/kg7ajm.com.nginx  deploy/sw.js
#
# The blog output is NOT handled here: CI rsyncs the built site straight into
# /var/www/kg7ajm.com/blog/ and this script only normalises its ownership.

set -uo pipefail

DRY=0
STAGE=/tmp/kg7ajm-stage
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) STAGE="$arg" ;;
  esac
done

DOCROOT=/var/www/kg7ajm.com
BLOG="$DOCROOT/blog"
RETIRE=/var/www/kg7ajm-retire
VHOST=/etc/nginx/sites-available/kg7ajm.com
ENABLED=/etc/nginx/sites-enabled/kg7ajm.com
TS=$(date +%Y%m%d-%H%M%S)
DATE=$(date +%Y%m%d)
changed=0

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. validate the staged inputs -------------------------------------------
for f in hub/index.html hub/favicon.svg hub/robots.txt deploy/kg7ajm.com.nginx deploy/sw.js; do
  [ -f "$STAGE/$f" ] || fail "staged file missing: $STAGE/$f"
done
grep -q 'server_name kg7ajm.com' "$STAGE/deploy/kg7ajm.com.nginx" \
  || fail "staged vhost does not look like the kg7ajm.com vhost"
grep -q '<h1>' "$STAGE/hub/index.html" || fail "staged hub page looks empty"

# --- 1. static files ----------------------------------------------------------
install_file() {  # src dst label
  local src="$1" dst="$2" label="$3"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    say "  = $label (unchanged)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    say "  ~ $label (would be updated)"
    changed=1
    return 0
  fi
  install -o www-data -g www-data -m 644 "$src" "$dst" || fail "could not install $dst"
  say "  + $label (updated)"
  changed=1
}

say "static site -> $DOCROOT"
[ "$DRY" = 1 ] || mkdir -p "$DOCROOT"
install_file "$STAGE/hub/index.html"  "$DOCROOT/index.html"  "index.html"
install_file "$STAGE/hub/favicon.svg" "$DOCROOT/favicon.svg" "favicon.svg"
install_file "$STAGE/hub/robots.txt"  "$DOCROOT/robots.txt"  "robots.txt"

say "kill switch -> $RETIRE"
[ "$DRY" = 1 ] || mkdir -p "$RETIRE"
install_file "$STAGE/deploy/sw.js" "$RETIRE/sw.js" "sw.js"

if [ -d "$BLOG" ]; then
  if [ "$DRY" = 1 ]; then
    say "blog/  would be chowned to www-data ($(find "$BLOG" -type f 2>/dev/null | wc -l) files)"
  else
    chown -R www-data:www-data "$BLOG"
    say "  = blog/ ownership normalised ($(find "$BLOG" -type f | wc -l) files)"
  fi
fi

# --- 2. vhost, gated on nginx -t ---------------------------------------------
say "vhost -> $VHOST"
if [ -f "$VHOST" ] && cmp -s "$STAGE/deploy/kg7ajm.com.nginx" "$VHOST"; then
  say "  = vhost unchanged, no reload"
else
  if [ "$DRY" = 1 ]; then
    say "  ~ vhost would be updated"
  else
    BAK="/root/kg7ajm.com.nginx.bak-$TS"
    if [ -f "$VHOST" ]; then
      cp "$VHOST" "$BAK" || fail "could not back up the current vhost"
      cp "$VHOST" "/etc/nginx/backups/kg7ajm.com.pre-deploy-$DATE" 2>/dev/null || true
    fi
    install -m 644 "$STAGE/deploy/kg7ajm.com.nginx" "$VHOST" || fail "could not install the vhost"
    ln -sfn "$VHOST" "$ENABLED"

    if nginx -t >/tmp/kg7ajm-nginx-t.log 2>&1; then
      systemctl reload nginx || fail "nginx reload failed"
      say "  + vhost updated, nginx reloaded"
    else
      say "  ! nginx -t rejected the new vhost:"
      sed 's/^/      /' /tmp/kg7ajm-nginx-t.log
      if [ -f "$BAK" ]; then
        cp "$BAK" "$VHOST"
        say "  < restored $BAK"
      else
        rm -f "$VHOST" "$ENABLED"
        say "  < removed the new vhost (nothing to restore)"
      fi
      if nginx -t >/dev/null 2>&1; then
        say "  < previous configuration tests clean again, nginx never reloaded"
      else
        say "  ! CONFIG STILL BROKEN, this needs a human"
      fi
      exit 1
    fi
  fi
  changed=1
fi

say ""
if [ "$DRY" = 1 ]; then
  say "dry run: $changed area(s) would change"
else
  say "done: $changed area(s) changed"
fi
exit 0
