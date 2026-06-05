#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Healthcheck finale Debian/OCI"

run() {
  echo
  echo "### $*"
  "$@" || true
}

run hostnamectl
run bash -c 'cat /etc/os-release || true'
run uptime
run free -h
run df -hT
run swapon --show
run ip -br addr
run ip route
run ss -tulpn
run sudo sshd -t
run systemctl status ssh --no-pager
run systemctl --failed --no-pager
run bash -c 'command -v ufw >/dev/null 2>&1 && sudo ufw status verbose || echo "ufw non installato"'
run bash -c 'sudo iptables -S 2>/dev/null || true'
run bash -c 'sudo nft list ruleset 2>/dev/null | sed -n "1,160p" || true'
run bash -c 'getent hosts deb.debian.org || true'
run bash -c 'curl -I --max-time 10 https://deb.debian.org >/dev/null && echo "HTTPS OK" || echo "HTTPS FAIL"'
run sudo apt-get update
run bash -c 'cloud-init status --long 2>/dev/null || echo "cloud-init non disponibile"'

if [[ -f /var/run/reboot-required ]]; then
  echo
  echo "[WARN] Reboot richiesto. Fai reboot solo dopo backup/snapshot e verifica accesso."
fi

echo
echo "[OK] Healthcheck completato."
