#!/usr/bin/env bash
# Decrypt the latest wacli backup and restore DB files into the store.
# Refuses to overwrite an authenticated store unless --force is given.
# Never prints the age identity.
set -euo pipefail

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    -h|--help)
      echo "Usage: wacli-restore.sh [--force]"
      exit 0
      ;;
    *)
      echo "wacli-restore: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

WACLI="${WACLI:-/workspace/.wacli/bin/wacli}"
WACLI_BIN="/workspace/.wacli/bin/wacli-bin"
AGE="${AGE:-/workspace/.wacli/bin/age}"
STORE="${WACLI_STORE_DIR:-/workspace/.wacli-store}"
KEYS="/workspace/.wacli/keys"
REMOTE="git@github.com:marciocadar-cmd/whatsapp-backup.git"
GIT_SSH_COMMAND="ssh -i ${KEYS}/github_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${KEYS}/known_hosts -o HostName=140.82.112.3 -o HostKeyAlias=github.com"
export GIT_SSH_COMMAND

if [[ -x "$WACLI" && -d "$STORE" ]]; then
  status="$("$WACLI" auth status 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -q '^Authenticated' && [[ "$FORCE" != true ]]; then
    echo "wacli-restore: refusing to overwrite an authenticated store; pass --force" >&2
    exit 1
  fi
fi

identity=""
for candidate in \
  /cursor/stores/store-f7274a39-eb06-4bf4-a28d-1fa656d2d895/wacli/age-key.txt \
  "${KEYS}/age-key.txt"
do
  if [[ -f "$candidate" ]]; then
    identity="$candidate"
    break
  fi
done
if [[ -z "$identity" ]]; then
  echo "wacli-restore: age identity not found in the bot store or ${KEYS}" >&2
  exit 1
fi
if [[ ! -x "$AGE" ]]; then
  echo "wacli-restore: missing age binary at ${AGE}" >&2
  exit 1
fi

reinstall_wacli_bin() {
  local tmp api tarball checksums line
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/wacli-reinstall.XXXXXX")"
  # steipete/wacli redirects to the current official repo
  if ! curl -fsSL "https://api.github.com/repos/steipete/wacli/releases/latest" -o "${tmp}/release.json"; then
    curl -fsSL "https://api.github.com/repos/openclaw/wacli/releases/latest" -o "${tmp}/release.json"
  fi
  python3 - "$tmp" <<'PY'
import json, sys, urllib.request
from pathlib import Path
tmp = Path(sys.argv[1])
release = json.loads((tmp / "release.json").read_text())
assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
tarball_name = next((n for n in assets if n.endswith("_linux_amd64.tar.gz")), None)
if not tarball_name or "checksums.txt" not in assets:
    raise SystemExit("wacli-restore: latest release is missing linux_amd64 tarball or checksums.txt")
(tmp / "assets.txt").write_text(tarball_name + "\n" + assets[tarball_name] + "\n" + assets["checksums.txt"] + "\n")
PY
  local name url sums
  name="$(sed -n '1p' "${tmp}/assets.txt")"
  url="$(sed -n '2p' "${tmp}/assets.txt")"
  sums="$(sed -n '3p' "${tmp}/assets.txt")"
  curl -fsSL "$url" -o "${tmp}/${name}"
  curl -fsSL "$sums" -o "${tmp}/checksums.txt"
  (cd "$tmp" && grep -F "$name" checksums.txt | sha256sum -c)
  tar -xzf "${tmp}/${name}" -C "$tmp"
  install -m 755 "${tmp}/wacli" "$WACLI_BIN"
  if [[ ! -x "$WACLI" ]]; then
    printf '%s\n' '#!/bin/sh' 'WACLI_STORE_DIR=/workspace/.wacli-store exec /workspace/.wacli/bin/wacli-bin "$@"' > "$WACLI"
    chmod +x "$WACLI"
  fi
  rm -rf "$tmp"
  echo "wacli-restore: installed ${WACLI_BIN}"
}

if [[ ! -x "$WACLI_BIN" ]]; then
  echo "wacli-restore: wacli-bin missing; installing latest GitHub release"
  reinstall_wacli_bin
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wacli-restore.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "wacli-restore: cloning ${REMOTE}"
git clone --depth 1 "$REMOTE" "${tmp}/repo"
if [[ ! -f "${tmp}/repo/wacli-backup.tar.age" ]] && ls "${tmp}"/repo/wacli-backup.tar.age.part-* >/dev/null 2>&1; then
  cat "${tmp}"/repo/wacli-backup.tar.age.part-* > "${tmp}/repo/wacli-backup.tar.age"
fi
if [[ ! -f "${tmp}/repo/wacli-backup.tar.age" ]]; then
  echo "wacli-restore: backup archive missing from repo" >&2
  exit 1
fi

mkdir -p "${tmp}/extract"
echo "wacli-restore: decrypting archive"
"$AGE" -d -i "$identity" "${tmp}/repo/wacli-backup.tar.age" | tar -xzf - -C "${tmp}/extract"
shopt -s nullglob
restored=("${tmp}/extract"/*.db)
shopt -u nullglob
if [[ ${#restored[@]} -eq 0 ]]; then
  echo "wacli-restore: no *.db files in decrypted archive" >&2
  exit 1
fi

mkdir -p "$STORE"
chmod 700 "$STORE" || true
# Replace only DB files after a successful decrypt
for db in "${restored[@]}"; do
  install -m 600 "$db" "${STORE}/$(basename "$db")"
  echo "wacli-restore: restored $(basename "$db")"
done
echo "wacli-restore: store is ${STORE}"
