#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 04_firewall_base.sh
# Firewall locale Debian con UFW, prudente per OCI.
#
# Uso sicuro:
#   TRUSTED_CIDR="1.2.3.4/32" CONFIRM_FIREWALL=yes ./04_firewall_base.sh
#
# Accesso da ovunque, meno sicuro:
#   ALLOW_ANYWHERE=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
#
# Per aprire PDM 8443:
#   TRUSTED_CIDR="1.2.3.4/32" ENABLE_PDM_PORT=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
# ============================================================

TRUSTED_CIDR="${TRUSTED_CIDR:-}"
ALLOW_ANYWHERE="${ALLOW_ANYWHERE:-no}"
ENABLE_PDM_PORT="${ENABLE_PDM_PORT:-no}"
CONFIRM="${CONFIRM_FIREWALL:-no}"
FORCE_UFW_OCI="${FORCE_UFW_OCI:-no}"

if [[ -z "${TRUSTED_CIDR}" ]]; then
  if [[ "${ALLOW_ANYWHERE}" == "yes" ]]; then
    TRUSTED_CIDR="0.0.0.0/0"
    echo "[WARN] TRUSTED_CIDR non specificato: apro da ovunque perché ALLOW_ANYWHERE=yes"
  else
    cat <<'EOF'
[ERRORE]
Specifica TRUSTED_CIDR oppure abilita esplicitamente ALLOW_ANYWHERE=yes.

Esempio sicuro:
  TRUSTED_CIDR='1.2.3.4/32' CONFIRM_FIREWALL=yes ./04_firewall_base.sh

Esempio accesso da ovunque, meno sicuro:
  ALLOW_ANYWHERE=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
EOF
    exit 1
  fi
fi

IS_OCI="no"
if grep -qi oracle /sys/class/dmi/id/product_name 2>/dev/null || \
   grep -qi oracle /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || \
   cloud-init status --long 2>/dev/null | grep -qi 'DataSourceOracle'; then
  IS_OCI="yes"
fi

HAS_INSTANCE_SERVICES="no"
if sudo iptables -S 2>/dev/null | grep -q 'InstanceServices'; then
  HAS_INSTANCE_SERVICES="yes"
fi

if [[ "${IS_OCI}" == "yes" && "${HAS_INSTANCE_SERVICES}" == "yes" && "${FORCE_UFW_OCI}" != "yes" ]]; then
  cat <<'EOF'
[STOP]
Rilevate regole OCI InstanceServices in iptables.
Non abilito UFW automaticamente perché potrebbe alterare regole necessarie a metadata/DNS/iSCSI/servizi OCI.

Consigliato:
  1. restringi prima Security List / NSG OCI;
  2. mantieni iptables OCI intatto;
  3. usa questo script solo se sai cosa stai facendo:
       FORCE_UFW_OCI=yes TRUSTED_CIDR=... CONFIRM_FIREWALL=yes ./04_firewall_base.sh
EOF
  exit 0
fi

if [[ "${CONFIRM}" != "yes" ]]; then
  cat <<EOF
[STOP]
Questo script modifica il firewall locale.
Prima verifica:
  - sessione SSH aperta;
  - accesso alternativo testato;
  - Security List / NSG OCI coerenti;
  - TRUSTED_CIDR corretto: ${TRUSTED_CIDR}

Per procedere:
  TRUSTED_CIDR="${TRUSTED_CIDR}" CONFIRM_FIREWALL=yes ./04_firewall_base.sh
EOF
  exit 1
fi

sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw

SSH_PORT="$(sudo sshd -T | awk '/^port / {print $2; exit}')"
SSH_PORT="${SSH_PORT:-22}"

echo "[INFO] Configuro policy UFW"
sudo ufw default deny incoming
sudo ufw default allow outgoing

echo "[INFO] Permetto SSH da ${TRUSTED_CIDR} su porta ${SSH_PORT}"
sudo ufw allow from "${TRUSTED_CIDR}" to any port "${SSH_PORT}" proto tcp comment "SSH admin access"

if [[ "${ENABLE_PDM_PORT}" == "yes" ]]; then
  echo "[INFO] Permetto PDM 8443 da ${TRUSTED_CIDR}"
  sudo ufw allow from "${TRUSTED_CIDR}" to any port 8443 proto tcp comment "PDM web admin access"
fi

echo "[INFO] Stato prima dell'enable"
sudo ufw status verbose || true

echo "[INFO] Abilito UFW"
sudo ufw --force enable

echo "[OK] Firewall locale configurato"
sudo ufw status verbose
