#!/bin/bash
# (Re)start the inner Docker daemon. Needs the container to run under sysbox-runc.
# Run it after init-firewall.sh: the firewall flushes iptables, and restarting
# dockerd puts Docker's own rules (NAT, forwarding for inner containers) back.
set -euo pipefail

# Use the host's Docker Hub pull-through cache (registry-cache in compose.gitea.yml).
# Builds then get docker.io images from the cache, so the docker CLI (running as the
# firewalled agent) never needs Docker Hub's token service. The host is the default gateway.
HOST_IP=$(ip route | awk '/^default/ {print $3; exit}')
if [[ -n $HOST_IP ]]; then
  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["http://$HOST_IP:5000"],
  "insecure-registries": ["$HOST_IP:5000"]
}
EOF
fi

if pgrep -x dockerd >/dev/null; then
  pkill -x dockerd
  while pgrep -x dockerd >/dev/null; do sleep 0.5; done
fi
# Stale pid files survive a container restart and can block startup
rm -f /var/run/docker.pid /var/run/docker/containerd/containerd.pid

setsid nohup dockerd >/var/log/dockerd.log 2>&1 < /dev/null &

for _ in $(seq 30); do
  docker info >/dev/null 2>&1 && exit 0
  sleep 1
done
echo "dockerd did not start, see /var/log/dockerd.log" >&2
exit 1
