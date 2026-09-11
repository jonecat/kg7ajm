#!/bin/bash
# One-time setup: gives the kg7ajm.com deploy pipeline its four repo secrets.
#
# Safe to re-run. It only installs the public key when the server does not already accept
# it, and every server connection uses THIS key with IdentitiesOnly + BatchMode, so ssh
# can never fall back to another identity and prompt for a passphrase that belongs to a
# different key. That fallback is what made the first version of this script confusing:
# it asked for the passphrase of an old key, which looks like a rejected password.
#
# Nothing here is echoed into a log, a commit or a chat: the Tailscale key is read with
# echo off and piped to gh through a mode-600 temp file, and the private key goes straight
# from disk into the repo secret.

set -euo pipefail

REPO=jonecat/kg7ajm
KEY="$HOME/.ssh/kg7ajm_deploy_ed25519"
COMMENT="kg7ajm.com deploy (github actions)"

echo "== 1/4  a dedicated deploy key for this repo =="
if [ -f "$KEY" ]; then
  echo "  reusing $KEY"
else
  ssh-keygen -t ed25519 -N "" -C "$COMMENT" -f "$KEY"
fi
echo "  public half:"
sed 's/^/    /' "$KEY.pub"

echo
echo "== 2/4  does the server already accept it? =="
read -rp "copper01 tailnet address the runner will use (100.123.227.126): " HOST
[ -n "$HOST" ] || { echo "  no host given"; exit 1; }

probe() {
  ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=accept-new "root@$HOST" 'echo AUTH-OK' 2>/dev/null || true
}

if [ "$(probe)" = "AUTH-OK" ]; then
  echo "  yes, this key already authenticates. Nothing to install."
else
  echo "  no, it needs installing first."
  echo
  echo "  Installing it takes one connection with a credential you already have, so ssh may"
  echo "  ask for a passphrase. If it does, that passphrase belongs to one of your EXISTING"
  echo "  keys (for example ~/.ssh/id_rsa), not to the new deploy key and not to your Mac"
  echo "  login password. Ctrl-C is safe here: nothing has been changed yet."
  echo
  ssh "root@$HOST" 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
  # Append straight into authorized_keys. Do not wrap this in a remote command
  # substitution: the substitution swallows stdin and the append writes nothing.
  ssh "root@$HOST" 'cat >> /root/.ssh/authorized_keys' < "$KEY.pub"
  if [ "$(probe)" = "AUTH-OK" ]; then
    echo "  installed and verified."
  else
    echo "  the key still does not authenticate. Stop here and ask for help."
    exit 1
  fi
fi

echo
echo "== 3/4  repo secrets =="
# A Tailscale auth key for CI must be Reusable AND Ephemeral, tagged tag:ci, the same
# shape the rpt and hamdash deploys use. A single-use key burns on the first run and
# every later run fails with 'invalid key' while the step still reports success.
read -rsp "TAILSCALE_AUTHKEY (input hidden): " TSKEY
echo
[ -n "$TSKEY" ] || { echo "  no key given"; exit 1; }

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
echo "Prove the whole path:"
echo "  gh workflow run 'Deploy kg7ajm.com' --repo $REPO"
echo "  gh run list --repo $REPO --limit 3"
echo
echo "The private key stays at $KEY (mode 600). You can delete it after setup if you would"
echo "rather not keep a copy; CI uses the repo secret, not this file."
