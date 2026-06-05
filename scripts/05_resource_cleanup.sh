#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 05_resource_cleanup.sh
# Ubuntu OCI low-resource cleanup + tuning baseline
#
# Obiettivo:
# - rendere Ubuntu più snello e controllabile;
# - aggiungere tuning leggero per poca RAM/disco;
# - evitare modifiche firewall/SSH;
# - mantenere idempotenza dove possibile.
#
# NON fa:
# - UFW;
# - apertura porte;
# - modifiche SSH;
# - rimozione servizi critici OCI/rete.
# ============================================================

# -----------------------------
# Configurazione modificabile
# -----------------------------

SWAP_FILE_PATH="${SWAP_FILE_PATH:-/swapfile}"
SWAP_FILE_SIZE_MB="${SWAP_FILE_SIZE_MB:-1024}"

VM_SWAPPINESS="${VM_SWAPPINESS:-10}"
VM_OVERCOMMIT_MEMORY="${VM_OVERCOMMIT_MEMORY:-1}"
VM_VFS_CACHE_PRESSURE="${VM_VFS_CACHE_PRESSURE:-200}"

# 0 consigliato: lascia ICMP attivo per troubleshooting.
# 1: ignora ping ICMP.
DISABLE_ICMP="${DISABLE_ICMP:-0}"

# Installa tool diagnostici utili ma non essenziali.
# 0 = più snello; 1 = installa htop iotop sysstat ncdu.
INSTALL_DIAG_TOOLS="${INSTALL_DIAG_TOOLS:-0}"

# Abilita raccolta sysstat/sar.
# Ha overhead basso, ma su macchina minimale puoi lasciarlo spento.
ENABLE_SYSSTAT="${ENABLE_SYSSTAT:-0}"

# Limita spazio journal systemd.
ENABLE_JOURNAL_LIMITS="${ENABLE_JOURNAL_LIMITS:-1}"
JOURNAL_SYSTEM_MAX_USE="${JOURNAL_SYSTEM_MAX_USE:-100M}"
JOURNAL_RUNTIME_MAX_USE="${JOURNAL_RUNTIME_MAX_USE:-50M}"
JOURNAL_MAX_RETENTION_SEC="${JOURNAL_MAX_RETENTION_SEC:-7day}"

# Rimozione snapd: rende Ubuntu più "Debian-like", ma può rompere software installato via snap.
# Default: non rimuove.
REMOVE_SNAPD="${REMOVE_SNAPD:-0}"
REMOVE_SNAPD_FORCE="${REMOVE_SNAPD_FORCE:-0}"

# Disabilita Ubuntu motd/news se presenti.
DISABLE_MOTD_NEWS="${DISABLE_MOTD_NEWS:-1}"

# Abilita fstrim.timer se disponibile.
ENABLE_FSTRIM="${ENABLE_FSTRIM:-1}"

# Servizi extra da disabilitare, separati da spazio.
# Esempio:
# DISABLE_SERVICES="apache2.service bluetooth.service" CONFIRM_DISABLE_SERVICES=yes ./05_resource_cleanup.sh
DISABLE_SERVICES="${DISABLE_SERVICES:-}"
CONFIRM_DISABLE_SERVICES="${CONFIRM_DISABLE_SERVICES:-no}"

SYSCTL_FILE="/etc/sysctl.d/99-low-resource-tuning.conf"
BACKUP_ROOT="/root/pre-hardening-backup"

# -----------------------------
# Utility
# -----------------------------

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
    if ! command -v sudo >/dev/null 2>&1; then
      die "sudo non disponibile. Esegui come root o installa sudo."
    fi
    sudo -v
  fi
}

backup_file_once() {
  local file="$1"

  if [[ ! -e "$file" ]]; then
    return 0
  fi

  ${SUDO} mkdir -p "$BACKUP_ROOT"

  local safe_name
  safe_name="$(echo "$file" | sed 's#/#_#g')"
  local backup_file="${BACKUP_ROOT}/${safe_name}.bak-before-cleanup"

  if [[ ! -e "$backup_file" ]]; then
    log "Backup di ${file} in ${backup_file}"
    ${SUDO} cp -a "$file" "$backup_file"
  fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "Impossibile rilevare il sistema operativo."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Sistema rilevato: ${PRETTY_NAME:-unknown}. Lo script è pensato per Ubuntu."
  else
    log "Sistema rilevato: ${PRETTY_NAME:-Ubuntu}"
  fi
}

is_protected_service() {
  local svc="$1"

  case "$svc" in
    ssh|ssh.service|sshd|sshd.service|\
    cloud-init|cloud-init.service|cloud-config.service|cloud-final.service|cloud-init-local.service|\
    systemd-networkd|systemd-networkd.service|NetworkManager|NetworkManager.service|\
    systemd-resolved|systemd-resolved.service|\
    systemd-timesyncd|systemd-timesyncd.service|chrony|chrony.service|\
    open-iscsi|open-iscsi.service|iscsid|iscsid.service|multipathd|multipathd.service|\
    oracle-cloud-agent|oracle-cloud-agent.service|\
    dbus|dbus.service|systemd-journald|systemd-journald.service)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# -----------------------------
# APT cleanup e tool opzionali
# -----------------------------

apt_cleanup_and_optional_tools() {
  log "Aggiornamento cache APT"
  ${SUDO} apt-get update

  if [[ "$INSTALL_DIAG_TOOLS" == "1" ]]; then
    log "Installazione tool diagnostici opzionali"
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      gnupg \
      htop \
      iotop \
      sysstat \
      ncdu
  else
    log "Salto installazione tool diagnostici opzionali"
    log "Per abilitarli: INSTALL_DIAG_TOOLS=1 ./05_resource_cleanup.sh"
  fi

  log "Rimozione pacchetti non più necessari"
  ${SUDO} apt-get autoremove -y

  log "Pulizia cache APT"
  ${SUDO} apt-get autoclean -y
}

# -----------------------------
# Swap
# -----------------------------

configure_swap() {
  log "Verifica swap"

  swapon --show || true

  if swapon --show=NAME --noheadings | grep -qE '.+'; then
    if swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE_PATH"; then
      log "Swap file ${SWAP_FILE_PATH} già attivo"
    else
      warn "È già presente uno swap diverso. Non creo ${SWAP_FILE_PATH}."
      warn "Questo è prudente: evita doppio swap non voluto."
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
    if [[ "$created_now" == "1" ]]; then
      log "Inizializzazione swap file con mkswap"
      ${SUDO} mkswap "$SWAP_FILE_PATH"
    else
      die "${SWAP_FILE_PATH} esiste ma non sembra uno swap file. Non lo sovrascrivo."
    fi
  else
    log "Swap file già formattato"
  fi

  if ! swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE_PATH"; then
    log "Attivazione swap"
    ${SUDO} swapon "$SWAP_FILE_PATH"
  else
    log "Swap già attivo"
  fi

  backup_file_once /etc/fstab

  if ! grep -Eq "^[[:space:]]*${SWAP_FILE_PATH//\//\\/}[[:space:]]+" /etc/fstab; then
    log "Aggiunta swap a /etc/fstab"
    echo "${SWAP_FILE_PATH} none swap sw 0 0" | ${SUDO} tee -a /etc/fstab >/dev/null
  else
    log "Swap già presente in /etc/fstab"
  fi
}

# -----------------------------
# Kernel / VM tuning
# -----------------------------

configure_sysctl() {
  log "Configurazione sysctl in ${SYSCTL_FILE}"

  if [[ "$VM_OVERCOMMIT_MEMORY" == "1" ]]; then
    warn "vm.overcommit_memory=1 può aiutare alcuni workload, ma aumenta il rischio di OOM su RAM bassa."
  fi

  if [[ "$DISABLE_ICMP" == "1" ]]; then
    warn "Stai disabilitando ICMP echo. Non è hardening forte e peggiora troubleshooting."
  fi

  ${SUDO} tee "$SYSCTL_FILE" >/dev/null <<EOF
# Low-resource tuning baseline
# Managed by 05_resource_cleanup.sh

# Riduce la tendenza del kernel a usare swap.
vm.swappiness = ${VM_SWAPPINESS}

# 1 = permette overcommit memoria.
# Utile in alcuni workload containerizzati, ma può aumentare rischio OOM.
vm.overcommit_memory = ${VM_OVERCOMMIT_MEMORY}

# Più alto = libera più aggressivamente cache inode/dentry.
# Su VPS con poca RAM può aiutare, ma può aumentare I/O disco.
vm.vfs_cache_pressure = ${VM_VFS_CACHE_PRESSURE}

# 1 = ignora ping ICMP; 0 = comportamento normale.
# Bloccare ICMP non è una misura di hardening sostanziale.
net.ipv4.icmp_echo_ignore_all = ${DISABLE_ICMP}
EOF

  log "Applicazione sysctl"
  ${SUDO} sysctl -p "$SYSCTL_FILE"
}

# -----------------------------
# Sysstat opzionale
# -----------------------------

configure_sysstat() {
  if [[ "$ENABLE_SYSSTAT" != "1" ]]; then
    log "Sysstat non abilitato"
    log "Per abilitarlo: INSTALL_DIAG_TOOLS=1 ENABLE_SYSSTAT=1 ./05_resource_cleanup.sh"
    return 0
  fi

  log "Abilitazione sysstat"

  if ! dpkg -s sysstat >/dev/null 2>&1; then
    log "sysstat non installato, lo installo"
    ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sysstat
  fi

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

# -----------------------------
# Journald leggero
# -----------------------------

configure_journald_limits() {
  if [[ "$ENABLE_JOURNAL_LIMITS" != "1" ]]; then
    log "Limiti journald non modificati"
    return 0
  fi

  log "Configurazione limiti journald"

  ${SUDO} mkdir -p /etc/systemd/journald.conf.d

  ${SUDO} tee /etc/systemd/journald.conf.d/99-low-resource.conf >/dev/null <<EOF
# Managed by 05_resource_cleanup.sh
[Journal]
SystemMaxUse=${JOURNAL_SYSTEM_MAX_USE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
MaxRetentionSec=${JOURNAL_MAX_RETENTION_SEC}
Compress=yes
EOF

  ${SUDO} systemctl restart systemd-journald

  log "Uso disco journal:"
  journalctl --disk-usage || true
}

# -----------------------------
# MOTD/news Ubuntu
# -----------------------------

disable_motd_news() {
  if [[ "$DISABLE_MOTD_NEWS" != "1" ]]; then
    log "MOTD/news non modificato"
    return 0
  fi

  log "Disabilitazione Ubuntu motd-news se presente"

  if [[ -f /etc/default/motd-news ]]; then
    backup_file_once /etc/default/motd-news

    if grep -q '^ENABLED=' /etc/default/motd-news; then
      ${SUDO} sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    else
      echo 'ENABLED=0' | ${SUDO} tee -a /etc/default/motd-news >/dev/null
    fi
  fi

  if systemctl list-unit-files | grep -q '^motd-news.timer'; then
    ${SUDO} systemctl disable --now motd-news.timer || true
  fi
}

# -----------------------------
# fstrim
# -----------------------------

enable_fstrim() {
  if [[ "$ENABLE_FSTRIM" != "1" ]]; then
    log "fstrim.timer non modificato"
    return 0
  fi

  if systemctl list-unit-files | grep -q '^fstrim.timer'; then
    log "Abilitazione fstrim.timer"
    ${SUDO} systemctl enable --now fstrim.timer || true
  else
    log "fstrim.timer non presente"
  fi
}

# -----------------------------
# Snapd opzionale
# -----------------------------

remove_snapd_optional() {
  if [[ "$REMOVE_SNAPD" != "1" ]]; then
    log "snapd non rimosso"
    log "Per rimuoverlo: REMOVE_SNAPD=1 ./05_resource_cleanup.sh"
    return 0
  fi

  if ! dpkg -s snapd >/dev/null 2>&1; then
    log "snapd non installato"
    return 0
  fi

  warn "Rimozione snapd richiesta."
  warn "Questo rende Ubuntu più minimale, ma può rompere software installato via snap."

  if command -v snap >/dev/null 2>&1; then
    echo
    echo "Snap installati:"
    snap list || true
    echo
  fi

  if [[ "$REMOVE_SNAPD_FORCE" != "1" ]]; then
    cat <<'EOF'
[STOP]
Non rimuovo snapd senza conferma forte.

Per procedere:
  REMOVE_SNAPD=1 REMOVE_SNAPD_FORCE=1 ./05_resource_cleanup.sh

Prima verifica di non usare pacchetti snap importanti.
EOF
    return 0
  fi

  log "Rimozione snap installati, se presenti"

  if command -v snap >/dev/null 2>&1; then
    mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)

    # Rimuovo prima snap applicativi, poi base/snapd.
    for s in "${snaps[@]:-}"; do
      case "$s" in
        core|core18|core20|core22|core24|snapd)
          ;;
        *)
          ${SUDO} snap remove "$s" || true
          ;;
      esac
    done

    for s in snapd core24 core22 core20 core18 core; do
      ${SUDO} snap remove "$s" || true
    done
  fi

  log "Purge snapd"
  ${SUDO} apt-get purge -y snapd || true
  ${SUDO} apt-get autoremove -y
  ${SUDO} rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || true

  log "Blocca reinstallazione automatica snapd via apt-mark hold"
  ${SUDO} apt-mark hold snapd || true
}

# -----------------------------
# Disabilitazione servizi opzionale
# -----------------------------

disable_optional_services() {
  if [[ -z "$DISABLE_SERVICES" ]]; then
    log "Nessun servizio extra richiesto per disabilitazione"
    return 0
  fi

  if [[ "$CONFIRM_DISABLE_SERVICES" != "yes" ]]; then
    cat <<EOF
[STOP]
Hai richiesto di disabilitare:
  ${DISABLE_SERVICES}

Per procedere:
  DISABLE_SERVICES="${DISABLE_SERVICES}" CONFIRM_DISABLE_SERVICES=yes ./05_resource_cleanup.sh
EOF
    return 0
  fi

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

# -----------------------------
# Report finale
# -----------------------------

final_report() {
  log "Report finale"

  echo
  echo "Swap:"
  swapon --show || true

  echo
  echo "Memoria:"
  free -h || true

  echo
  echo "Disco:"
  df -hT || true

  echo
  echo "Sysctl applicati:"
  sysctl \
    vm.swappiness \
    vm.overcommit_memory \
    vm.vfs_cache_pressure \
    net.ipv4.icmp_echo_ignore_all || true

  echo
  echo "Journal:"
  journalctl --disk-usage || true

  echo
  echo "Servizi falliti:"
  systemctl --failed || true

  if [[ -f /var/run/reboot-required ]]; then
    warn "Reboot richiesto. Fallo solo dopo snapshot/backup e verifica accesso SSH."
  fi
}

# -----------------------------
# Main
# -----------------------------

main() {
  require_sudo
  require_ubuntu

  warn "Questo script NON modifica SSH e NON configura firewall."
  warn "Su Ubuntu OCI non usare UFW alla cieca: gestisci prima Security List/NSG."

  apt_cleanup_and_optional_tools
  configure_swap
  configure_sysctl
  configure_sysstat
  configure_journald_limits
  disable_motd_news
  enable_fstrim
  remove_snapd_optional
  disable_optional_services
  final_report

  log "Cleanup/tuning completato."
}

main "$@"