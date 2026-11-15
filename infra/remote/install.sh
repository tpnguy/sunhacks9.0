#!/bin/bash
# Runs on the EC2 box as root via `aws ssm send-command` (see push.sh).
# Usage: install.sh <host>   (bundle files sit next to this script)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=${1:-$(cat /opt/dubstudio/host)}

# First boot may still be running UserData (Caddy download, CW agent...).
cloud-init status --wait >/dev/null 2>&1 || true

id dubstudio >/dev/null 2>&1 || useradd --system --home-dir /opt/dubstudio --shell /sbin/nologin dubstudio
mkdir -p /opt/dubstudio /var/log/dubstudio
chown dubstudio:dubstudio /var/log/dubstudio

install -m 0755 "$HERE/dubstudio-server" /opt/dubstudio/dubstudio-server.new
mv -f /opt/dubstudio/dubstudio-server.new /opt/dubstudio/dubstudio-server
install -m 0755 "$HERE/fetch-env.sh" /opt/dubstudio/fetch-env.sh
[ -f "$HERE/clips.json" ] && install -m 0644 "$HERE/clips.json" /opt/dubstudio/clips.json
if [ -d "$HERE/prompts" ]; then rm -rf /opt/dubstudio/prompts; cp -r "$HERE/prompts" /opt/dubstudio/prompts; chmod -R a+rX /opt/dubstudio/prompts; fi
install -m 0644 "$HERE/dubstudio.service" /etc/systemd/system/dubstudio.service

# Caddy config (only reload if it changed)
sed "s/__HOST__/$HOST/g" "$HERE/Caddyfile.tmpl" > /tmp/Caddyfile.new
if ! cmp -s /tmp/Caddyfile.new /etc/caddy/Caddyfile; then
  install -m 0644 /tmp/Caddyfile.new /etc/caddy/Caddyfile
  systemctl reload caddy || systemctl restart caddy
fi
systemctl is-active --quiet caddy || systemctl restart caddy

/opt/dubstudio/fetch-env.sh
systemctl daemon-reload
systemctl enable dubstudio >/dev/null 2>&1
systemctl restart dubstudio

for _ in $(seq 1 20); do
  if curl -fsS http://localhost:8080/healthz; then echo; echo "install: healthy on :8080"; exit 0; fi
  sleep 1
done
echo "install: dubstudio did not become healthy; last log lines:" >&2
tail -n 40 /var/log/dubstudio/server.log >&2 || true
systemctl status dubstudio --no-pager >&2 || true
exit 1
