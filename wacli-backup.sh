#!/usr/bin/env bash
# Snapshot the wacli store DBs, age-encrypt them, and force-push a single
# orphan commit to the private backup repo. Never writes age or deploy keys.
set -euo pipefail

WACLI="${WACLI:-/workspace/.wacli/bin/wacli}"
AGE="${AGE:-/workspace/.wacli/bin/age}"
STORE="${WACLI_STORE_DIR:-/workspace/.wacli-store}"
LOCK="/workspace/.wacli/backup.lock"
REPO="/workspace/.wacli/backup-repo"
KEYS="/workspace/.wacli/keys"
RECIPIENT_FILE="${KEYS}/age-recipient.txt"
REMOTE="git@github.com:marciocadar-cmd/whatsapp-backup.git"
# github.com resolves to an HTTP egress proxy on this box, so raw SSH to
# github.com:22 fails. A public GitHub git anycast IP works with the deploy key.
GIT_SSH_COMMAND="ssh -i ${KEYS}/github_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${KEYS}/known_hosts -o HostName=140.82.112.3 -o HostKeyAlias=github.com"
export GIT_SSH_COMMAND

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "wacli-backup: another backup holds ${LOCK}" >&2
  exit 1
fi

if [[ ! -x "$WACLI" ]]; then
  echo "wacli-backup: missing wacli wrapper at ${WACLI}" >&2
  exit 1
fi
status="$("$WACLI" auth status 2>&1 || true)"
if ! printf '%s\n' "$status" | grep -q '^Authenticated'; then
  echo "wacli-backup: refusing to run; auth status is not Authenticated" >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

recipient=""
if [[ -f "$RECIPIENT_FILE" ]]; then
  recipient="$(tr -d '[:space:]' < "$RECIPIENT_FILE")"
else
  for ident in \
    /cursor/stores/store-f7274a39-eb06-4bf4-a28d-1fa656d2d895/wacli/age-key.txt \
    "${KEYS}/age-key.txt"
  do
    if [[ -f "$ident" ]]; then
      recipient="$(/workspace/.wacli/bin/age-keygen -y "$ident" | tr -d '[:space:]')"
      break
    fi
  done
fi
if [[ -z "$recipient" || "$recipient" != age1* ]]; then
  echo "wacli-backup: could not load age recipient (no secrets printed)" >&2
  exit 1
fi
if [[ ! -x "$AGE" ]]; then
  echo "wacli-backup: missing age binary at ${AGE}" >&2
  exit 1
fi

snapshot_db() {
  local src="$1" dst="$2"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "file:${src}?mode=ro" ".backup '${dst}'"
    return
  fi
  python3 - "$src" "$dst" <<'PY'
import os, sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
src_uri = "file:{}?mode=ro".format(os.path.abspath(src))
src_conn = sqlite3.connect(src_uri, uri=True, timeout=60)
dst_conn = sqlite3.connect(dst)
try:
    src_conn.backup(dst_conn)
    dst_conn.commit()
finally:
    dst_conn.close()
    src_conn.close()
PY
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wacli-backup.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

snap="${tmp}/snap"
mkdir -p "$snap"
shopt -s nullglob
dbs=("${STORE}"/*.db)
shopt -u nullglob
if [[ ${#dbs[@]} -eq 0 ]]; then
  echo "wacli-backup: no *.db files in ${STORE}" >&2
  exit 1
fi
for db in "${dbs[@]}"; do
  base="$(basename "$db")"
  echo "wacli-backup: snapshot ${base}"
  snapshot_db "$db" "${snap}/${base}"
done

# gzip inside the tar so the encrypted blob stays under GitHub's 100 MiB file limit
echo "wacli-backup: encrypting snapshot"
tar -C "$snap" -czf - . | "$AGE" -r "$recipient" -o "${tmp}/wacli-backup.tar.age"
if [[ ! -s "${tmp}/wacli-backup.tar.age" ]]; then
  echo "wacli-backup: encrypted archive is empty" >&2
  exit 1
fi

if [[ ! -d "${REPO}/.git" ]]; then
  mkdir -p "$(dirname "$REPO")"
  if ! git clone "$REMOTE" "$REPO"; then
    mkdir -p "$REPO"
    git -C "$REPO" init -b main
    git -C "$REPO" remote add origin "$REMOTE"
  fi
fi
git -C "$REPO" remote set-url origin "$REMOTE"
git -C "$REPO" config user.name "wacli-backup"
git -C "$REPO" config user.email "wacli-backup@local"

# Replace worktree contents, then make a single orphan commit and force-push.
find "$REPO" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$REPO" checkout --orphan "backup-new"
git -C "$REPO" rm -rf --cached . >/dev/null 2>&1 || true

split -b 90M -d "${tmp}/wacli-backup.tar.age" "${REPO}/wacli-backup.tar.age.part-"
cp -f /workspace/.wacli/bin/wacli "${REPO}/wacli"
cp -f /workspace/.wacli/bin/wacli-backup.sh "${REPO}/wacli-backup.sh"
cp -f /workspace/.wacli/bin/wacli-restore.sh "${REPO}/wacli-restore.sh"
chmod +x "${REPO}/wacli" "${REPO}/wacli-backup.sh" "${REPO}/wacli-restore.sh"

cat > "${REPO}/README.md" << 'README'
# Encrypted wacli backup

This private repository holds an age-encrypted snapshot of the wacli SQLite
databases (`wacli-backup.tar.age`: a gzip-compressed tar of `*.db` files).

Helper scripts from the box are included for convenience:

- `wacli` — wrapper that points the store at `/workspace/.wacli-store`
- `wacli-backup.sh` — online DB snapshot, encrypt, and force-push a single orphan commit
- `wacli-restore.sh` — decrypt and restore the store (refuses if the current store is authenticated unless `--force`)

Secrets are not stored in this repository. The age identity and the GitHub
deploy key live only on the box (the age identity is also kept in the bot
store). To restore, run `wacli-restore.sh` on a box that has the age identity.

Each push replaces history with one new orphan commit so the repo stays small.
README

git -C "$REPO" add -A
# Avoid committing leftover key material if any ever appeared in the worktree
git -C "$REPO" reset HEAD -- \
  '*.key' '*age-key*' '*id_ed25519*' '*github_deploy*' '*secret*' 2>/dev/null || true
if git -C "$REPO" diff --cached --name-only | grep -Eiq 'age-key|github_deploy|id_ed25519|\.key$'; then
  echo "wacli-backup: refusing to commit key material" >&2
  git -C "$REPO" diff --cached --name-only >&2
  exit 1
fi

git -C "$REPO" commit -m "Encrypted wacli store backup $(date -Iseconds)"
git -C "$REPO" branch -M main
git -C "$REPO" push --force origin main
echo "wacli-backup: pushed $(cat "${REPO}"/wacli-backup.tar.age.part-* | wc -c) bytes to ${REMOTE}"
