#!/usr/bin/env bash
# install-sysbox.sh — install the Sysbox container runtime on the host (Debian/Ubuntu).
# The devcontainer runs with --runtime=sysbox-runc so it can run its own Docker daemon.
#
#   ./install-sysbox.sh
#
# Installs the pinned, checksum-verified Sysbox release without restarting Docker
# or touching any containers.
#
# Why that works: Sysbox's installer refuses to run while any container exists if
# /etc/docker/daemon.json lacks "bip" and "default-address-pools", because it wants
# to add its own (172.20.0.0/16, 172.25.0.0/16) and restart Docker. Those ranges can
# clash with existing compose networks, so this script first writes Docker's
# *current* bridge address and its default pools into daemon.json. Nothing about
# Docker's networking changes, and the installer only reloads Docker (SIGHUP) to
# register the sysbox-runc runtime.
set -euo pipefail

VERSION=0.7.1
declare -A SHA256=(
  [amd64]=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
  [arm64]=04ca894ae0b53f0fa54eaacc173ce40363c9a95ea5450f773716a84ef650a69b
)
DAEMON_JSON=/etc/docker/daemon.json

say() { printf '\033[1;34m==\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found; run this on the host"
command -v dpkg >/dev/null || die "only Debian/Ubuntu are supported (.deb package)"
command -v jq >/dev/null || { say "Installing jq"; sudo apt-get install -y jq; }

sysbox_registered() {
  docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"sysbox-runc"'
}

if sysbox_registered; then
  say "Sysbox is already installed and registered with Docker:"
  dpkg-query -W sysbox-ce 2>/dev/null || true
  exit 0
fi

# 1. Pin Docker's current network settings so the installer needn't restart Docker
has_network_config() {
  sudo test -s "$DAEMON_JSON" &&
    sudo jq -e 'has("bip") and (.bip != "") and ((."default-address-pools" // []) | length > 0)' \
      "$DAEMON_JSON" >/dev/null
}

if has_network_config; then
  say "$DAEMON_JSON already sets bip and default-address-pools"
else
  gw="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
  subnet="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}')"
  [[ $gw =~ ^[0-9.]+$ && $subnet =~ /[0-9]+$ ]] || die "could not read the default bridge network ($gw, $subnet)"
  bip="$gw/${subnet##*/}"

  # Docker's built-in defaults: 172.17-31.0.0/16 and 192.168.0.0/16 split into /20s
  pools='[range(17;32) | {base: "172.\(.).0.0/16", size: 16}] + [{base: "192.168.0.0/16", size: 20}]'

  current='{}'
  if sudo test -s "$DAEMON_JSON"; then
    current="$(sudo cat "$DAEMON_JSON")"
    sudo cp "$DAEMON_JSON" "$DAEMON_JSON.bak.$(date +%Y%m%d%H%M%S)"
    say "Backed up $DAEMON_JSON"
  fi

  new="$(jq --indent 4 --arg bip "$bip" \
    ".bip = (.bip // \"\" | if . == \"\" then \$bip else . end)
     | .\"default-address-pools\" = (if ((.\"default-address-pools\" // []) | length) > 0
                                     then .\"default-address-pools\" else $pools end)" \
    <<<"$current")" || die "$DAEMON_JSON is not valid JSON"

  sudo mkdir -p "$(dirname "$DAEMON_JSON")"
  printf '%s\n' "$new" | sudo tee "$DAEMON_JSON" >/dev/null
  say "Wrote current network settings to $DAEMON_JSON (bip $bip, Docker's default pools)"
fi

# 2. Install (or finish configuring a previously failed install)
if dpkg-query -W -f '${Status}' sysbox-ce 2>/dev/null | grep -q 'half-configured\|unpacked'; then
  say "Finishing the earlier, partly configured sysbox-ce install"
  sudo dpkg --configure sysbox-ce
else
  ARCH="$(dpkg --print-architecture)"
  [[ -n ${SHA256[$ARCH]:-} ]] || die "unsupported architecture: $ARCH"
  DEB="sysbox-ce_${VERSION}.linux_${ARCH}.deb"
  URL="https://github.com/nestybox/sysbox/releases/download/v${VERSION}/${DEB}"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  chmod 755 "$TMP"   # so apt's _apt user can read the .deb

  say "Downloading $DEB"
  curl -fL --progress-bar -o "$TMP/$DEB" "$URL"
  echo "${SHA256[$ARCH]}  $TMP/$DEB" | sha256sum -c --quiet - || die "checksum mismatch for $DEB"
  chmod 644 "$TMP/$DEB"
  say "Checksum OK"

  say "Installing (needs sudo)"
  sudo apt-get install -y "$TMP/$DEB"
fi

# 3. Verify
for _ in $(seq 10); do sysbox_registered && break; sleep 1; done
sysbox_registered \
  || die "Sysbox installed but Docker does not list sysbox-runc; check 'systemctl status sysbox' and $DAEMON_JSON"
systemctl is-active --quiet sysbox || die "sysbox service is not active; check 'systemctl status sysbox'"

say "Sysbox $VERSION installed; Docker was not restarted. Next: ./tsl rebuild"
