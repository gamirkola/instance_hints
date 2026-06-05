#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 07_replace_default_user.sh
#
# Crea un nuovo utente admin copiando:
# - authorized_keys dall'utente di default;
# - gruppi secondari utili;
# - permessi sudo.
#
# Poi permette, in modo separato e confermato, di:
# - disabilitare login SSH dell'utente vecchio;
# - eliminare l'utente vecchio.
#
# Uso tipico:
#   NEW_USER=mirko ./07_replace_default_user.sh create
#   NEW_USER=mirko ./07_replace_default_user.sh verify
#   NEW_USER=mirko ./07_replace_default_user.sh disable-old
#   NEW_USER=mirko CONFIRM_DELETE_OLD_USER=yes ./07_replace_default_user.sh delete-old
# ============================================================

OLD_USER="${OLD_USER:-ubuntu}"
NEW_USER="${NEW_USER:-}"
ACTION="${1:-create}"

# Se vuoi aggiungere o sovrascrivere manualmente i gruppi:
# EXTRA_GROUPS="sudo,adm,lxd" NEW_USER=mirko ./07_replace_default_user.sh create
EXTRA_GROUPS="${EXTRA_GROUPS:-}"

# 1 = crea una regola sudoers esplicita passwordless per il nuovo utente.
# Su immagini cloud spesso il gruppo sudo è già NOPASSWD, ma qui lo rendiamo esplicito se vuoi.
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-1}"

# 1 = rimuove authorized_keys dell'utente vecchio quando fai disable-old.
# Questo blocca il login SSH via chiave senza cancellare l'utente.
DISABLE_OLD_AUTHORIZED_KEYS="${DISABLE_OLD_AUTHORIZED_KEYS:-1}"

# 1 = cambia shell del vecchio utente a nologin quando fai disable-old.
# Più forte, ma va fatto solo dopo test nuovo utente.
DISABLE_OLD_SHELL="${DISABLE_OLD_SHELL:-1}"

BACKUP_ROOT="/root/pre-hardening-backup/user-migration-$(date +%F-%H%M%S)"

log() {
  echo -e "\n[+] $*"
}

warn() {
  echo -e "\n[!] $*" >&2
}

die() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo non disponibile."
    sudo -v
  fi
}

validate_users() {
  [[ -n "${NEW_USER}" ]] || die "Specifica NEW_USER. Esempio: NEW_USER=mirko $0 create"

  if [[ "${NEW_USER}" == "${OLD_USER}" ]]; then
    die "NEW_USER e OLD_USER coincidono. Non ha senso procedere."
  fi

  if [[ "${NEW_USER}" == "root" || "${OLD_USER}" == "root" ]]; then
    die "Non usare root come OLD_USER o NEW_USER."
  fi

  if ! [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    die "Nome utente non valido: ${NEW_USER}"
  fi

  id "${OLD_USER}" >/dev/null 2>&1 || die "OLD_USER non esiste: ${OLD_USER}"
}

old_home() {
  getent passwd "${OLD_USER}" | cut -d: -f6
}

new_home() {
  getent passwd "${NEW_USER}" | cut -d: -f6
}

backup_old_user_files() {
  local ohome
  ohome="$(old_home)"

  log "Backup file utente vecchio in ${BACKUP_ROOT}"
  ${SUDO} mkdir -p "${BACKUP_ROOT}"

  if [[ -d "${ohome}/.ssh" ]]; then
    ${SUDO} cp -a "${ohome}/.ssh" "${BACKUP_ROOT}/${OLD_USER}.ssh"
  fi

  getent passwd "${OLD_USER}" | ${SUDO} tee "${BACKUP_ROOT}/${OLD_USER}.passwd" >/dev/null
  id "${OLD_USER}" | ${SUDO} tee "${BACKUP_ROOT}/${OLD_USER}.id" >/dev/null
}

copy_authorized_keys() {
  local ohome nhome
  ohome="$(old_home)"
  nhome="$(new_home)"

  if [[ ! -f "${ohome}/.ssh/authorized_keys" ]]; then
    die "Non trovo ${ohome}/.ssh/authorized_keys. Non procedo per evitare lockout."
  fi

  log "Copio authorized_keys da ${OLD_USER} a ${NEW_USER}"

  ${SUDO} install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${nhome}/.ssh"
  ${SUDO} cp "${ohome}/.ssh/authorized_keys" "${nhome}/.ssh/authorized_keys"
  ${SUDO} chown "${NEW_USER}:${NEW_USER}" "${nhome}/.ssh/authorized_keys"
  ${SUDO} chmod 600 "${nhome}/.ssh/authorized_keys"
}

copy_groups() {
  log "Copio gruppi secondari utili da ${OLD_USER} a ${NEW_USER}"

  local groups_csv
  groups_csv="$(id -nG "${OLD_USER}" | tr ' ' '\n' | grep -v "^${OLD_USER}$" | paste -sd, -)"

  if [[ -n "${EXTRA_GROUPS}" ]]; then
    if [[ -n "${groups_csv}" ]]; then
      groups_csv="${groups_csv},${EXTRA_GROUPS}"
    else
      groups_csv="${EXTRA_GROUPS}"
    fi
  fi

  if [[ -n "${groups_csv}" ]]; then
    ${SUDO} usermod -aG "${groups_csv}" "${NEW_USER}"
    log "Gruppi assegnati: ${groups_csv}"
  else
    warn "Nessun gruppo secondario da copiare."
  fi

  # Sicurezza: sudo deve esserci comunque.
  ${SUDO} usermod -aG sudo "${NEW_USER}"
}

configure_sudoers() {
  if [[ "${ENABLE_PASSWORDLESS_SUDO}" != "1" ]]; then
    log "Sudoers passwordless non modificato"
    return 0
  fi

  log "Creo sudoers esplicito per ${NEW_USER}"

  local sudoers_file="/etc/sudoers.d/90-${NEW_USER}-cloud-admin"

  echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" | ${SUDO} tee "${sudoers_file}" >/dev/null
  ${SUDO} chmod 0440 "${sudoers_file}"
  ${SUDO} visudo -cf "${sudoers_file}" >/dev/null
}

create_user() {
  require_sudo
  validate_users
  backup_old_user_files

  if id "${NEW_USER}" >/dev/null 2>&1; then
    log "Utente ${NEW_USER} già esistente"
  else
    log "Creo utente ${NEW_USER}"
    ${SUDO} adduser --disabled-password --gecos "" "${NEW_USER}"
  fi

  copy_groups
  copy_authorized_keys
  configure_sudoers

  log "Blocco password locale del nuovo utente"
  ${SUDO} passwd -l "${NEW_USER}" >/dev/null || true

  cat <<EOF

[OK] Utente ${NEW_USER} creato/preparato.

ORA NON CHIUDERE QUESTA SESSIONE.

Apri un secondo terminale e testa:

  ssh ${NEW_USER}@<IP_PUBBLICO>
  whoami
  id
  sudo -n true && echo "sudo passwordless OK"
  sudo hostnamectl

Se tutto funziona, esegui:

  NEW_USER=${NEW_USER} ./07_replace_default_user.sh verify

EOF
}

verify_user() {
  require_sudo
  validate_users

  log "Verifica utente ${NEW_USER}"

  id "${NEW_USER}"
  test -f "$(new_home)/.ssh/authorized_keys" || die "authorized_keys mancante per ${NEW_USER}"

  ${SUDO} -l -U "${NEW_USER}" || true

  echo
  echo "Comandi da provare da un secondo terminale:"
  echo "  ssh ${NEW_USER}@<IP_PUBBLICO>"
  echo "  sudo -n true && echo OK"
  echo
  echo "[INFO] Se il login funziona, puoi disabilitare ${OLD_USER}:"
  echo "  NEW_USER=${NEW_USER} ./07_replace_default_user.sh disable-old"
}

disable_old_user() {
  require_sudo
  validate_users

  local ohome
  ohome="$(old_home)"

  cat <<EOF
[ATTENZIONE]
Stai per disabilitare il login dell'utente vecchio: ${OLD_USER}

Prima devi avere già verificato:
  1. ssh ${NEW_USER}@<IP_PUBBLICO>
  2. sudo funzionante con ${NEW_USER}
  3. questa sessione SSH ancora aperta

Per procedere devi impostare:
  CONFIRM_DISABLE_OLD_USER=yes

EOF

  if [[ "${CONFIRM_DISABLE_OLD_USER:-no}" != "yes" ]]; then
    die "Conferma mancante. Riesegui con CONFIRM_DISABLE_OLD_USER=yes"
  fi

  backup_old_user_files

  if [[ "${DISABLE_OLD_AUTHORIZED_KEYS}" == "1" && -f "${ohome}/.ssh/authorized_keys" ]]; then
    log "Disabilito authorized_keys di ${OLD_USER}"
    ${SUDO} mv "${ohome}/.ssh/authorized_keys" "${ohome}/.ssh/authorized_keys.disabled-$(date +%F-%H%M%S)"
  fi

  if [[ "${DISABLE_OLD_SHELL}" == "1" ]]; then
    log "Cambio shell di ${OLD_USER} a /usr/sbin/nologin"
    ${SUDO} usermod -s /usr/sbin/nologin "${OLD_USER}"
  fi

  log "Blocco password di ${OLD_USER}"
  ${SUDO} passwd -l "${OLD_USER}" >/dev/null || true

  cat <<EOF

[OK] Utente ${OLD_USER} disabilitato.

Verifica:
  ssh ${OLD_USER}@<IP_PUBBLICO>
  ssh ${NEW_USER}@<IP_PUBBLICO>

Rollback, se necessario dalla sessione ancora aperta:
  sudo usermod -s /bin/bash ${OLD_USER}
  sudo cp ${BACKUP_ROOT}/${OLD_USER}.ssh/authorized_keys $(old_home)/.ssh/authorized_keys
  sudo chown ${OLD_USER}:${OLD_USER} $(old_home)/.ssh/authorized_keys
  sudo chmod 600 $(old_home)/.ssh/authorized_keys

EOF
}

delete_old_user() {
  require_sudo
  validate_users

  cat <<EOF
[PERICOLO]
Stai per eliminare l'utente ${OLD_USER}.

Questa operazione è distruttiva.
Consiglio: fallo solo dopo almeno un reboot e dopo aver verificato che ${NEW_USER} funzioni.

Per procedere:
  CONFIRM_DELETE_OLD_USER=yes NEW_USER=${NEW_USER} ./07_replace_default_user.sh delete-old

EOF

  if [[ "${CONFIRM_DELETE_OLD_USER:-no}" != "yes" ]]; then
    die "Conferma cancellazione mancante."
  fi

  backup_old_user_files

  log "Elimino utente ${OLD_USER} mantenendo backup in ${BACKUP_ROOT}"
  ${SUDO} deluser --remove-home "${OLD_USER}"

  log "Utente ${OLD_USER} eliminato."
}

case "${ACTION}" in
  create)
    create_user
    ;;
  verify)
    verify_user
    ;;
  disable-old)
    disable_old_user
    ;;
  delete-old)
    delete_old_user
    ;;
  *)
    cat <<EOF
Uso:
  NEW_USER=mirko $0 create
  NEW_USER=mirko $0 verify
  NEW_USER=mirko CONFIRM_DISABLE_OLD_USER=yes $0 disable-old
  NEW_USER=mirko CONFIRM_DELETE_OLD_USER=yes $0 delete-old

Variabili:
  OLD_USER=ubuntu
  ENABLE_PASSWORDLESS_SUDO=1
  DISABLE_OLD_AUTHORIZED_KEYS=1
  DISABLE_OLD_SHELL=1
EOF
    exit 1
    ;;
esac