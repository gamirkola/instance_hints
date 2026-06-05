#!/usr/bin/env bash
set -euo pipefail

#usage ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh

ADMIN_USER="${ADMIN_USER:-}"
CONFIRM="${CONFIRM_SSH_HARDENING:-no}"

if [[ -z "${ADMIN_USER}" ]]; then
  echo "[ERRORE] Specifica ADMIN_USER. Esempio:"
  echo "  ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh"
  exit 1
fi

if [[ "${CONFIRM}" != "yes" ]]; then
  cat <<EOF
[STOP]
Questo script modifica SSH. Prima verifica:
  1. Login con chiave per ${ADMIN_USER}
  2. sudo funzionante
  3. sessione SSH attuale aperta
  4. snapshot/backup OCI creato

Poi esegui:
  ADMIN_USER=${ADMIN_USER} CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
EOF
  exit 1
fi

if [[ ! -f "$(eval echo "~${ADMIN_USER}")/.ssh/authorized_keys" ]]; then
  echo "[ERRORE] Mancano authorized_keys per ${ADMIN_USER}. Non procedo."
  exit 1
fi

if ! id "${ADMIN_USER}" | grep -qE 'groups=.*(sudo|wheel)'; then
  echo "[ERRORE] ${ADMIN_USER} non sembra nel gruppo sudo/wheel. Non procedo."
  exit 1
fi

BACKUP_DIR="/root/pre-hardening-backup/ssh-$(date +%F-%H%M%S)"
sudo mkdir -p "${BACKUP_DIR}"
sudo cp -a /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config"
sudo cp -a /etc/ssh/sshd_config.d "${BACKUP_DIR}/sshd_config.d" 2>/dev/null || true

echo "[INFO] Creo drop-in SSH hardening"
sudo tee /etc/ssh/sshd_config.d/99-hardening-safe.conf >/dev/null <<'EOF'
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

echo "[INFO] Test sintassi sshd"
sudo sshd -t

echo "[INFO] Preparo rollback automatico tra 3 minuti se non confermi"
sudo tee /root/ssh-hardening-rollback.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
sleep 180
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

echo "[INFO] Ricarico SSH senza riavviare brutalmente"
sudo systemctl reload ssh || sudo systemctl reload sshd

cat <<'EOF'

[AZIONE ORA]
1. NON chiudere questa sessione.
2. Apri un secondo terminale e prova il login SSH.
3. Se funziona:
     sudo touch /run/ssh-hardening-confirmed
4. Se non confermi entro 3 minuti, lo script prova a ripristinare la config precedente.

EOF