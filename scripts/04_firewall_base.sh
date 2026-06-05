#!/usr/bin/env bash
set -euo pipefail

#USAGE TRUSTED_CIDR="1.2.3.4/32" CONFIRM_FIREWALL=yes ./04_firewall_base.sh
#USAGE TRUSTED_CIDR="1.2.3.4/32" ENABLE_PDM_PORT=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh

TRUSTED_CIDR="${TRUSTED_CIDR:-}"
ENABLE_PDM_PORT="${ENABLE_PDM_PORT:-no}"
CONFIRM="${CONFIRM_FIREWALL:-no}"
FORCE_UFW_OCI="${FORCE_UFW_OCI:-no}"

if [[ -z "${TRUSTED_CIDR}" ]]; then
  echo "[ERRORE] Specifica TRUSTED_CIDR, es:"
  echo "  TRUSTED_CIDR='1.2.3.4/32' ./04_firewall_base.sh"
  exit 1
fi

OS_ID="$(. /etc/os-release && echo "${ID}")"
IS_OCI="no"

if grep -qi oracle /sys/class/dmi/id/product_name 2>/dev/null || \
   grep -qi oracle /sys/class/dmi/id/chassis_asset_tag 2>/dev/null; then
  IS_OCI="yes"
fi

if [[ "${IS_OCI}" == "yes" && "${OS_ID}" == "ubuntu" && "${FORCE_UFW_OCI}" != "yes" ]]; then
  cat <<'EOF'
[STOP]
Rilevata probabile istanza Ubuntu su OCI.

OCI documenta un caveat importante: non usare UFW per modificare le regole
firewall sulle immagini Ubuntu OCI senza seguire procedure specifiche, perché
potresti compromettere il boot/networking.

Per questa istanza:
  1. restringi prima Security List / NSG lato OCI;
  2. lascia UFW inattivo finché non hai un piano specifico;
  3. usa fail2ban per SSH;
  4. se vuoi forzare comunque UFW:
       FORCE_UFW_OCI=yes TRUSTED_CIDR=... CONFIRM_FIREWALL=yes ./04_firewall_base.sh
EOF
  exit 0
fi

if [[ "${CONFIRM}" != "yes" ]]; then
  cat <<EOF
[STOP]
Questo script può modificare il firewall locale.
Prima verifica:
  - sessione SSH aperta;
  - accesso alternativo testato;
  - NSG/Security List OCI coerenti;
  - TRUSTED_CIDR corretto: ${TRUSTED_CIDR}

Per procedere:
  TRUSTED_CIDR="${TRUSTED_CIDR}" CONFIRM_FIREWALL=yes ./04_firewall_base.sh
EOF
  exit 1
fi

echo "[INFO] Installo UFW se assente"
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw

SSH_PORT="$(sudo sshd -T | awk '/^port / {print $2; exit}')"
SSH_PORT="${SSH_PORT:-22}"

echo "[INFO] Configuro policy UFW"
sudo ufw default deny incoming
sudo ufw default allow outgoing

echo "[INFO] Permetto SSH solo da ${TRUSTED_CIDR} su porta ${SSH_PORT}"
sudo ufw allow from "${TRUSTED_CIDR}" to any port "${SSH_PORT}" proto tcp comment "SSH trusted admin"

if [[ "${ENABLE_PDM_PORT}" == "yes" ]]; then
  echo "[INFO] Permetto PDM 8443 solo da ${TRUSTED_CIDR}"
  sudo ufw allow from "${TRUSTED_CIDR}" to any port 8443 proto tcp comment "PDM web trusted admin"
fi

echo "[INFO] Stato prima dell'enable"
sudo ufw status verbose || true

echo "[INFO] Abilito UFW"
sudo ufw --force enable

echo "[OK] Firewall locale configurato."
sudo ufw status verbose