#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Inventario iniziale - sola lettura"
echo "=================================================="

run() {
  echo
  echo "### $*"
  "$@" || true
}

run hostnamectl
run bash -c 'lsb_release -a || cat /etc/os-release'
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
run systemctl --type=service --state=running
run systemctl --failed
run sudo ufw status verbose
run sudo iptables -S
run cloud-init status --long
run bash -c 'dpkg -l | wc -l'
run bash -c 'apt list --upgradable 2>/dev/null | tail -n +2 | wc -l'

echo
echo "[INFO] Fine inventario."