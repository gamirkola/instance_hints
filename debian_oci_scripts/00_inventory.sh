#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Inventario iniziale Debian/OCI - sola lettura"
echo "=================================================="

run() {
  echo
  echo "### $*"
  "$@" || true
}

run hostnamectl
run bash -c 'cat /etc/os-release || true'
run bash -c 'lsb_release -a 2>/dev/null || true'
run uname -a
run whoami
run id
run uptime
run free -h
run df -hT
run lsblk
run ip -br addr
run ip route
run ss -tulpn
run systemctl --type=service --state=running --no-pager
run systemctl --failed --no-pager
run bash -c 'command -v ufw >/dev/null 2>&1 && sudo ufw status verbose || echo "ufw non installato"'
run bash -c 'sudo iptables -S 2>/dev/null || true'
run bash -c 'sudo nft list ruleset 2>/dev/null | sed -n "1,160p" || true'
run bash -c 'cloud-init status --long 2>/dev/null || echo "cloud-init non disponibile"'
run bash -c 'dpkg -l | wc -l'
run bash -c 'apt list --upgradable 2>/dev/null | tail -n +2 | wc -l'
run bash -c 'test -f /var/run/reboot-required && cat /var/run/reboot-required || echo "nessun reboot-required file"'

echo
echo "[INFO] Fine inventario."
