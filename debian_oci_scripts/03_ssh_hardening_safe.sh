#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 03_ssh_hardening_safe.sh
# Hardening SSH conservativo con rollback automatico.
# Uso:
#   ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
# Dopo il test da seconda sessione:
#   sudo touch /run/ssh-hardening-confirmed
# ============================================================

ADMIN_USER="${ADMIN_USER:-}"
CONFIRM="${CONFIRM_SSH_HARDENING:-no}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-180}"
BACKUP_DIR="/root/pre-hardening-backup/ssh-$(date +%F-%H%M%S)"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="${DROPIN_DIR}/99-hardening-safe.conf"

log() { echo -e "\n[+] $*"; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

[[ -n "${ADMIN_USER}" ]] || die "Specifica ADMIN_USER. Esempio: ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh"

if [[ "${CONFIRM}" != "yes" ]]; then
  cat <<EOF
[STOP]
Questo script modifica SSH. Prima verifica:
  1. login con chiave per ${ADMIN_USER};
  2. sudo funzionante;
  3. sessione SSH attuale aperta;
  4. snapshot/backup OCI creato.

Poi esegui:
  ADMIN_USER=${ADMIN_USER} CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
EOF
  exit 1
fi

[[ -f "$(eval echo "~${ADMIN_USER}")/.ssh/authorized_keys" ]] || die "Mancano authorized_keys per ${ADMIN_USER}."
id "${ADMIN_USER}" | grep -qE 'groups=.*(sudo|wheel)' || die "${ADMIN_USER} non sembra nel gruppo sudo/wheel."

log "Backup configurazione SSH in ${BACKUP_DIR}"
sudo mkdir -p "${BACKUP_DIR}" "${DROPIN_DIR}"
sudo cp -a /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config"
sudo cp -a "${DROPIN_DIR}" "${BACKUP_DIR}/sshd_config.d" 2>/dev/null || true

log "Creo drop-in SSH hardening"
sudo tee "${DROPIN_FILE}" >/dev/null <<'EOF'
# Hardening SSH conservativo.
# Non cambia porta SSH per evitare lockout.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

log "Test sintassi sshd"
sudo sshd -t

log "Preparo rollback automatico tra ${ROLLBACK_SECONDS} secondi se non confermi"
sudo tee /root/ssh-hardening-rollback.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
sleep ${ROLLBACK_SECONDS}
if [[ ! -f /run/ssh-hardening-confirmed ]]; then
  cp -a "${BACKUP_DIR}/sshd_config" /etc/ssh/sshd_config
  rm -rf /etc/ssh/sshd_config.d
  cp -a "${BACKUP_DIR}/sshd_config.d" /etc/ssh/sshd_config.d 2>/dev/null || mkdir -p /etc/ssh/sshd_config.d
  sshd -t
  systemctl reload ssh || systemctl reload sshd
fi
EOF
sudo chmod 700 /root/ssh-hardening-rollback.sh
sudo nohup /root/ssh-hardening-rollback.sh >/root/ssh-hardening-rollback.log 2>&1 &

log "Ricarico SSH"
sudo systemctl reload ssh || sudo systemctl reload sshd

cat <<EOF

[AZIONE ORA]
1. NON chiudere questa sessione.
2. Apri un secondo terminale e prova il login SSH.
3. Se funziona:
     sudo touch /run/ssh-hardening-confirmed
4. Se non confermi entro ${ROLLBACK_SECONDS} secondi, lo script prova a ripristinare la config precedente.

EOF
