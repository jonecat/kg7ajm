#!/bin/bash
# One-time setup: gives the kg7ajm.com deploy pipeline its four repo secrets.
#
# Run this on your Mac, from this repo. Nothing here is echoed to a chat, a log or a
# commit: the Tailscale key is read with echo off and piped to `gh secret set` through a
# mode-600 temp file, and the SSH private key never leaves this machine except into the
# repo secret itself.
#
# Prerequisites: `gh` logged in with admin on the repo, and SSH access to copper01.

set -euo pipefail

REPO=jonecat/kg7ajm
KEY="$HOME/.ssh/kg7ajm_deploy_ed25519"

echo "== 1/4  a dedicated deploy key for this repo =="
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "kg7ajm.com deploy (github actions)" -f "$KEY"
fi
echo "public half:"
sed 's/^/  /' "$KEY.pub"

echo
echo "== 2/4  install the public half on copper01 =="
read -rp "copper01 tailnet address (same SSH_HOST as the rpt and hamdash repos): " HOST
[ -n "$HOST" ] || { echo "no host given"; exit 1; }

# Append straight into authorized_keys. Do NOT wrap this in a remote command
# substitution like grep -qF \"\$(cat)\$PUB\": the substitution swallows stdin and the
# append silently writes nothing.
ssh -o StrictHostKeyChecking=accept-new "root@$HOST" 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
ssh "root@$HOST" 'cat >> /root/.ssh/authorized_keys' < "$KEY.pub"
echo "verifying the key actually works:"
ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$HOST" \
  'echo "  AUTH-OK as $(whoami) on $(hostname)"'

echo
echo "== 3/4  repo secrets =="
# A Tailscale auth key for CI must be Reusable AND Ephemeral, tagged tag:ci. A
# single-use key burns on the first run and every later run fails with 'invalid key'
# while the step still reports success. Create one in the Tailscale admin console.
read -rsp "TAILSCALE_AUTHKEY (input hidden, nothing is echoed): " TSKEY
echo
[ -n "$TSKEY" ] || { echo "no key given"; exit 1; }

umask 077
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
printf '%s' "$TSKEY" > "$TMP"
gh secret set TAILSCALE_AUTHKEY --repo "$REPO" < "$TMP"
unset TSKEY

gh secret set SSH_KEY  --repo "$REPO" < "$KEY"
gh secret set SSH_HOST --repo "$REPO" --body "$HOST"
gh secret set SSH_USER --repo "$REPO" --body "root"

echo
echo "== 4/4  done =="
gh secret list --repo "$REPO"
echo
echo "Now run the workflow once to prove the path end to end:"
echo "  gh workflow run 'Deploy kg7ajm.com' --repo $REPO"
echo "  gh run list --repo $REPO --limit 3"
echo
echo "The private key stays at $KEY (mode 600). Delete it after setup if you would"
echo "rather not keep a copy on disk; the repo secret is what CI uses."
