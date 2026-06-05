#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 05_resource_cleanup.sh
# Debian OCI/VPS low-resource cleanup + tuning baseline.
# Non modifica SSH e non configura firewall.
# ============================================================

SWAP_FILE_PATH="${SWAP_FILE_PATH:-/swapfile}"
SWAP_FILE_SIZE_MB="${SWAP_FILE_SIZE_MB:-1024}"
VM_SWAPPINESS="${VM_SWAPPINESS:-10}"
VM_OVERCOMMIT_MEMORY="${VM_OVERCOMMIT_MEMORY:-1}"
VM_VFS_CACHE_PRESSURE="${VM_VFS_CACHE_PRESSURE:-200}"
DISABLE_ICMP="${DISABLE_ICMP:-0}"
INSTALL_DIAG_TOOLS="${INSTALL_DIAG_TOOLS:-0}"
ENABLE_SYSSTAT="${ENABLE_SYSSTAT:-0}"
ENABLE_JOURNAL_LIMITS="${ENABLE_JOURNAL_LIMITS:-1}"
JOURNAL_SYSTEM_MAX_USE="${JOURNAL_SYSTEM_MAX_USE:-100M}"
JOURNAL_RUNTIME_MAX_USE="${JOURNAL_RUNTIME_MAX_USE:-50M}"
JOURNAL_MAX_RETENTION_SEC="${JOURNAL_MAX_RETENTION_SEC:-7day}"
ENABLE_FSTRIM="${ENABLE_FSTRIM:-1}"
DISABLE_SERVICES="${DISABLE_SERVICES:-}"
CONFIRM_DISABLE_SERVICES="${CONFIRM_DISABLE_SERVICES:-no}"
SYSCTL_FILE="/etc/sysctl.d/99-low-resource-tuning.conf"
BACKUP_ROOT="/root/pre-hardening-backup"

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo non disponibile. Esegui come root o installa sudo."
    sudo -v
  fi
}

require_debian() {
  [[ -f /etc/os-release ]] || die "Impossibile rilevare il sistema operativo."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    warn "Sistema rilevato: ${PRETTY_NAME:-unknown}. Lo script è pensato per Debian."
  else
    log "Sistema rilevato: ${PRETTY_NAME:-Debian}"
  fi
}

backup_file_once() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  ${SUDO} mkdir -p "$BACKUP_ROOT"
  local safe_name backup_file
  safe_name="$(echo "$file" | sed 's#/#_#g')"
  backup_file="${BACKUP_ROOT}/${safe_name}.bak-before-cleanup"
  if [[ ! -e "$backup_file" ]]; then
    log "Backup di ${file} in ${backup_file}"
    ${SUDO} cp -a "$file" "$backup_file"
  fi
}

is_protected_service() {
  local svc="$1"
  case "$svc" in
    ssh|ssh.service|sshd|sshd.service|\
    cloud-init|cloud-init.service|cloud-config.service|cloud-final.service|cloud-init-local.service|\
    networking|networking.service|systemd-networkd|systemd-networkd.service|NetworkManager|NetworkManager.service|\
    systemd-resolved|systemd-resolved.service|\
    systemd-timesyncd|systemd-timesyncd.service|chrony|chrony.service|\
    open-iscsi|open-iscsi.service|iscsid|iscsid.service|multipathd|multipathd.service|\
    dbus|dbus.service|systemd-journald|systemd-journald.service)
      return 0 ;;
    *) return 1 ;;
  esac
}

apt_cleanup_and_optional_tools() {
  log "Aggiornamento cache APT"
  ${SUDO} apt-get update

  if [[ "$INSTALL_DIAG_TOOLS" == "1" ]]; then
    log "Installazione tool diagnostici opzionali"
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg htop iotop sysstat ncdu
  else
    log "Salto tool diagnostici opzionali. Per abilitarli: INSTALL_DIAG_TOOLS=1 ./05_resource_cleanup.sh"
  fi

  log "Rimozione pacchetti non più necessari"
  ${SUDO} apt-get autoremove -y
  log "Pulizia cache APT"
  ${SUDO} apt-get autoclean -y
}

configure_swap() {
  log "Verifica swap"
  swapon --show || true

  if swapon --show=NAME --noheadings | grep -qE '.+'; then
    if swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE_PATH"; then
      log "Swap file ${SWAP_FILE_PATH} già attivo"
    else
      warn "È già presente uno swap diverso. Non creo ${SWAP_FILE_PATH}."
      return 0
    fi
  fi

  log "Configurazione swap file: ${SWAP_FILE_PATH} (${SWAP_FILE_SIZE_MB} MB)"
  local created_now="0"

  if [[ ! -f "$SWAP_FILE_PATH" ]]; then
    log "Creazione swap file"
    if ! ${SUDO} fallocate -l "${SWAP_FILE_SIZE_MB}M" "$SWAP_FILE_PATH"; then
      warn "fallocate non riuscito, uso dd come fallback"
      ${SUDO} dd if=/dev/zero of="$SWAP_FILE_PATH" bs=1M count="$SWAP_FILE_SIZE_MB" status=progress
    fi
    created_now="1"
  else
    log "Swap file già presente"
  fi

  ${SUDO} chown root:root "$SWAP_FILE_PATH"
  ${SUDO} chmod 0600 "$SWAP_FILE_PATH"

  if ! file -b "$SWAP_FILE_PATH" | grep -qi "swap"; then
    [[ "$created_now" == "1" ]] || die "${SWAP_FILE_PATH} esiste ma non sembra swap. Non lo sovrascrivo."
    ${SUDO} mkswap "$SWAP_FILE_PATH"
  fi

  if ! swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE_PATH"; then
    ${SUDO} swapon "$SWAP_FILE_PATH"
  fi

  backup_file_once /etc/fstab
  if ! grep -Eq "^[[:space:]]*${SWAP_FILE_PATH//\//\\/}[[:space:]]+" /etc/fstab; then
    echo "${SWAP_FILE_PATH} none swap sw 0 0" | ${SUDO} tee -a /etc/fstab >/dev/null
  fi
}

configure_sysctl() {
  log "Configurazione sysctl in ${SYSCTL_FILE}"
  [[ "$VM_OVERCOMMIT_MEMORY" == "1" ]] && warn "vm.overcommit_memory=1 può aumentare rischio OOM su RAM bassa."
  [[ "$DISABLE_ICMP" == "1" ]] && warn "Disabilitare ICMP peggiora troubleshooting e non è hardening forte."

  ${SUDO} tee "$SYSCTL_FILE" >/dev/null <<EOF
# Low-resource tuning baseline
# Managed by 05_resource_cleanup.sh
vm.swappiness = ${VM_SWAPPINESS}
vm.overcommit_memory = ${VM_OVERCOMMIT_MEMORY}
vm.vfs_cache_pressure = ${VM_VFS_CACHE_PRESSURE}
net.ipv4.icmp_echo_ignore_all = ${DISABLE_ICMP}
EOF
  ${SUDO} sysctl -p "$SYSCTL_FILE"
}

configure_sysstat() {
  [[ "$ENABLE_SYSSTAT" == "1" ]] || { log "Sysstat non abilitato"; return 0; }
  log "Abilitazione sysstat"
  dpkg -s sysstat >/dev/null 2>&1 || ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sysstat

  if [[ -f /etc/default/sysstat ]]; then
    backup_file_once /etc/default/sysstat
    if grep -q '^ENABLED=' /etc/default/sysstat; then
      ${SUDO} sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
    else
      echo 'ENABLED="true"' | ${SUDO} tee -a /etc/default/sysstat >/dev/null
    fi
  else
    echo 'ENABLED="true"' | ${SUDO} tee /etc/default/sysstat >/dev/null
  fi

  ${SUDO} systemctl enable --now sysstat || true
  ${SUDO} systemctl restart sysstat || true
}

configure_journald_limits() {
  [[ "$ENABLE_JOURNAL_LIMITS" == "1" ]] || { log "Limiti journald non modificati"; return 0; }
  log "Configurazione limiti journald"
  ${SUDO} mkdir -p /etc/systemd/journald.conf.d
  ${SUDO} tee /etc/systemd/journald.conf.d/99-low-resource.conf >/dev/null <<EOF
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
MaxRetentionSec=${JOURNAL_MAX_RETENTION_SEC}
Compress=yes
EOF
  ${SUDO} systemctl restart systemd-journald
  journalctl --disk-usage || true
}

enable_fstrim() {
  [[ "$ENABLE_FSTRIM" == "1" ]] || { log "fstrim.timer non modificato"; return 0; }
  if systemctl list-unit-files | grep -q '^fstrim.timer'; then
    log "Abilitazione fstrim.timer"
    ${SUDO} systemctl enable --now fstrim.timer || true
  else
    log "fstrim.timer non presente"
  fi
}

disable_optional_services() {
  [[ -n "$DISABLE_SERVICES" ]] || { log "Nessun servizio extra richiesto per disabilitazione"; return 0; }
  [[ "$CONFIRM_DISABLE_SERVICES" == "yes" ]] || { warn "Conferma mancante: CONFIRM_DISABLE_SERVICES=yes"; return 0; }

  for svc in $DISABLE_SERVICES; do
    if is_protected_service "$svc"; then
      warn "Servizio protetto, non lo disabilito: ${svc}"
      continue
    fi
    if systemctl list-unit-files | grep -q "^${svc}"; then
      log "Disabilito servizio: ${svc}"
      ${SUDO} systemctl disable --now "$svc" || true
    else
      warn "Servizio non trovato: ${svc}"
    fi
  done
}

final_report() {
  log "Report finale"
  echo; echo "Swap:"; swapon --show || true
  echo; echo "Memoria:"; free -h || true
  echo; echo "Disco:"; df -hT || true
  echo; echo "Sysctl applicati:"; sysctl vm.swappiness vm.overcommit_memory vm.vfs_cache_pressure net.ipv4.icmp_echo_ignore_all || true
  echo; echo "Journal:"; journalctl --disk-usage || true
  echo; echo "Servizi falliti:"; systemctl --failed --no-pager || true
  [[ -f /var/run/reboot-required ]] && warn "Reboot richiesto. Fallo solo dopo snapshot/backup e verifica accesso SSH."
}

main() {
  require_sudo
  require_debian
  warn "Questo script NON modifica SSH e NON configura firewall."
  apt_cleanup_and_optional_tools
  configure_swap
  configure_sysctl
  configure_sysstat
  configure_journald_limits
  enable_fstrim
  disable_optional_services
  final_report
  log "Cleanup/tuning completato."
}

main "$@"
