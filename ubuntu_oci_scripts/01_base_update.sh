#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Aggiornamento base controllato"

if [[ "${EUID}" -eq 0 ]]; then
  echo "[ERRORE] Esegui come utente sudo, non direttamente root."
  exit 1
fi

echo "[INFO] Backup configurazioni APT"
sudo mkdir -p /root/pre-hardening-backup
sudo tar -czf "/root/pre-hardening-backup/apt-$(date +%F-%H%M%S).tar.gz" \
  /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true

echo "[INFO] apt update"
sudo apt update

echo "[INFO] Pacchetti aggiornabili:"
apt list --upgradable 2>/dev/null || true

cat <<'EOF'

[ATTENZIONE]
Lo script NON esegue upgrade automatico senza conferma.
Per procedere:
  CONFIRM_UPGRADE=yes ./01_base_update.sh

EOF

if [[ "${CONFIRM_UPGRADE:-no}" != "yes" ]]; then
  echo "[INFO] Nessun upgrade eseguito."
  exit 0
fi

echo "[INFO] Eseguo apt upgrade senza rimozioni aggressive"
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "[INFO] Installo strumenti minimi utili"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release sudo openssh-server

echo "[INFO] Verifica servizi falliti"
systemctl --failed || true

if [[ -f /var/run/reboot-required ]]; then
  echo "[WARN] Reboot richiesto. Prima crea/verifica snapshot OCI e accesso SSH."
fi

echo "[OK] Aggiornamento base completato."