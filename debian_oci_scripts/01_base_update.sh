#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 01_base_update.sh
# Aggiornamento base controllato per Debian su OCI/VPS.
# Non esegue full-upgrade senza conferma.
# ============================================================

CONFIRM_UPGRADE="${CONFIRM_UPGRADE:-no}"
RUN_FULL_UPGRADE="${RUN_FULL_UPGRADE:-no}"
INSTALL_BASE_TOOLS="${INSTALL_BASE_TOOLS:-yes}"
BACKUP_ROOT="/root/pre-hardening-backup"

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo non disponibile. Entra come root o installa sudo."
    sudo -v
  fi
}

require_debian() {
  [[ -f /etc/os-release ]] || die "Impossibile rilevare /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    warn "Sistema rilevato: ${PRETTY_NAME:-unknown}. Lo script è pensato per Debian."
  else
    log "Sistema Debian rilevato: ${PRETTY_NAME:-Debian}"
  fi
}

backup_apt_config() {
  log "Backup configurazioni APT"
  ${SUDO} mkdir -p "${BACKUP_ROOT}"
  ${SUDO} tar -czf "${BACKUP_ROOT}/apt-$(date +%F-%H%M%S).tar.gz" \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
}

main() {
  require_sudo
  require_debian
  backup_apt_config

  log "apt update"
  ${SUDO} apt-get update

  log "Pacchetti aggiornabili"
  apt list --upgradable 2>/dev/null || true

  if [[ "${CONFIRM_UPGRADE}" != "yes" ]]; then
    cat <<EOF

[INFO] Nessun upgrade eseguito.
Per upgrade conservativo:
  CONFIRM_UPGRADE=yes ./01_base_update.sh

Per full-upgrade, più invasivo:
  CONFIRM_UPGRADE=yes RUN_FULL_UPGRADE=yes ./01_base_update.sh

EOF
    exit 0
  fi

  if [[ "${RUN_FULL_UPGRADE}" == "yes" ]]; then
    warn "Eseguo full-upgrade: può installare/rimuovere pacchetti e aggiornare kernel. Snapshot consigliato."
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
  else
    log "Eseguo upgrade conservativo"
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi

  if [[ "${INSTALL_BASE_TOOLS}" == "yes" ]]; then
    log "Installazione strumenti base minimi"
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release sudo openssh-server apt-transport-https
  fi

  log "Verifica servizi falliti"
  systemctl --failed --no-pager || true

  if [[ -f /var/run/reboot-required ]]; then
    warn "Reboot richiesto. Prima verifica snapshot/backup e accesso SSH."
  fi

  log "Aggiornamento base completato."
}

main "$@"
