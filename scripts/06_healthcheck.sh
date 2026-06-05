#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Healthcheck finale"

run() {
  echo
  echo "### $*"
  "$@" || true
}

run hostnamectl
run uptime
run free -h
run df -hT
run swapon --show
run ip -br addr
run ip route
run ss -tulpn
run sudo sshd -t
run systemctl status ssh
run systemctl --failed
run sudo ufw status verbose
run sudo iptables -S
run bash -c 'getent hosts deb.debian.org || getent hosts archive.ubuntu.com || true'
run bash -c 'curl -I --max-time 10 https://www.google.com >/dev/null && echo "HTTPS OK" || echo "HTTPS FAIL"'
run sudo apt update
run cloud-init status --long

if [[ -f /var/run/reboot-required ]]; then
  echo
  echo "[WARN] Reboot richiesto. Fai reboot solo dopo backup/snapshot e verifica accesso."
fi

echo
echo "[OK] Healthcheck completato."