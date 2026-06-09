#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 08_pdm_lockdown_tailscale_iptables.sh
#
# Debian/PDM firewall lockdown for public interfaces.
#
# Goal:
# - close all inbound public ports except SSH;
# - keep Tailscale working;
# - allow PDM UI/API only through tailscale0;
# - avoid UFW;
# - preserve existing OCI/host rules by inserting an early custom chain;
# - provide automatic rollback to avoid SSH lockout.
#
# Usage:
#   sudo ./08_pdm_lockdown_tailscale_iptables.sh apply
#   # test SSH + Tailscale + PDM via Tailscale
#   sudo touch /run/pdm-firewall-confirmed
#   sudo ./08_pdm_lockdown_tailscale_iptables.sh persist
#
# Rollback:
#   sudo ./08_pdm_lockdown_tailscale_iptables.sh rollback
#
# Status:
#   sudo ./08_pdm_lockdown_tailscale_iptables.sh status
# ============================================================

ACTION="${1:-apply}"

SSH_PORT="${SSH_PORT:-22}"
TAILSCALE_IFACE="${TAILSCALE_IFACE:-tailscale0}"
TAILSCALE_UDP_PORT="${TAILSCALE_UDP_PORT:-41641}"

# yes = allow inbound UDP 41641 on the public interface for better direct Tailscale connections.
# Tailscale can usually work without inbound ports, but direct connections benefit from this.
ALLOW_TS_DIRECT_PORT="${ALLOW_TS_DIRECT_PORT:-yes}"

# ICMP is not a TCP/UDP service port. Keeping it enabled helps PMTU and troubleshooting.
ALLOW_ICMP="${ALLOW_ICMP:-yes}"

# Apply IPv6 rules if ip6tables is available.
ENABLE_IPV6="${ENABLE_IPV6:-yes}"

# Seconds before automatic rollback if /run/pdm-firewall-confirmed is not created.
ROLLBACK_DELAY_SECONDS="${ROLLBACK_DELAY_SECONDS:-180}"

CHAIN="PDM-LOCKDOWN"
BACKUP_DIR="/root/pdm-firewall-backup"
LATEST_BACKUP="${BACKUP_DIR}/latest"
CONFIRM_FILE="/run/pdm-firewall-confirmed"
ROLLBACK_SCRIPT="/root/pdm-firewall-rollback.sh"

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

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Esegui come root: sudo $0 ${ACTION}"
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_tools() {
  cmd_exists iptables || die "iptables non trovato. Installa iptables prima di procedere."

  if ! cmd_exists iptables-save || ! cmd_exists iptables-restore; then
    die "iptables-save/iptables-restore mancanti. Installa il pacchetto iptables."
  fi

  if [[ "${ENABLE_IPV6}" == "yes" ]]; then
    if ! cmd_exists ip6tables || ! cmd_exists ip6tables-save || ! cmd_exists ip6tables-restore; then
      warn "ip6tables non completo: salto IPv6."
      ENABLE_IPV6="no"
    fi
  fi
}

backup_rules() {
  log "Backup regole firewall correnti"
  mkdir -p "${BACKUP_DIR}"
  rm -rf "${LATEST_BACKUP}"
  mkdir -p "${LATEST_BACKUP}"

  iptables-save > "${LATEST_BACKUP}/iptables.rules"

  if [[ "${ENABLE_IPV6}" == "yes" ]]; then
    ip6tables-save > "${LATEST_BACKUP}/ip6tables.rules"
  fi

  cp -a "${LATEST_BACKUP}" "${BACKUP_DIR}/backup-$(date +%F-%H%M%S)"
}

restore_rules() {
  [[ -f "${LATEST_BACKUP}/iptables.rules" ]] || die "Backup IPv4 non trovato: ${LATEST_BACKUP}/iptables.rules"

  log "Ripristino regole IPv4"
  iptables-restore < "${LATEST_BACKUP}/iptables.rules"

  if [[ -f "${LATEST_BACKUP}/ip6tables.rules" ]] && cmd_exists ip6tables-restore; then
    log "Ripristino regole IPv6"
    ip6tables-restore < "${LATEST_BACKUP}/ip6tables.rules"
  fi

  log "Rollback completato"
}

chain_exists_v4() {
  iptables -nL "${CHAIN}" >/dev/null 2>&1
}

chain_exists_v6() {
  ip6tables -nL "${CHAIN}" >/dev/null 2>&1
}

remove_old_chain_v4() {
  while iptables -C INPUT -j "${CHAIN}" >/dev/null 2>&1; do
    iptables -D INPUT -j "${CHAIN}" || true
  done

  if chain_exists_v4; then
    iptables -F "${CHAIN}" || true
    iptables -X "${CHAIN}" || true
  fi
}

remove_old_chain_v6() {
  [[ "${ENABLE_IPV6}" == "yes" ]] || return 0

  while ip6tables -C INPUT -j "${CHAIN}" >/dev/null 2>&1; do
    ip6tables -D INPUT -j "${CHAIN}" || true
  done

  if chain_exists_v6; then
    ip6tables -F "${CHAIN}" || true
    ip6tables -X "${CHAIN}" || true
  fi
}

apply_ipv4_rules() {
  log "Applico regole IPv4 ${CHAIN}"

  remove_old_chain_v4

  iptables -N "${CHAIN}"

  # Safety and base traffic.
  iptables -A "${CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "${CHAIN}" -m conntrack --ctstate INVALID -j DROP
  iptables -A "${CHAIN}" -i lo -j ACCEPT

  # Tailscale overlay: PDM 8443 and any other tailnet access stay reachable through tailscale0.
  iptables -A "${CHAIN}" -i "${TAILSCALE_IFACE}" -j ACCEPT

  # Keep SSH reachable from public interfaces.
  iptables -A "${CHAIN}" -p tcp --dport "${SSH_PORT}" -m conntrack --ctstate NEW -j ACCEPT

  # Optional public UDP port for direct Tailscale peer connections.
  if [[ "${ALLOW_TS_DIRECT_PORT}" == "yes" ]]; then
    iptables -A "${CHAIN}" -p udp --dport "${TAILSCALE_UDP_PORT}" -j ACCEPT
  fi

  # DHCP client replies, useful on cloud DHCP networks.
  iptables -A "${CHAIN}" -p udp --sport 67 --dport 68 -j ACCEPT

  if [[ "${ALLOW_ICMP}" == "yes" ]]; then
    iptables -A "${CHAIN}" -p icmp -j ACCEPT
  fi

  # Everything else inbound is closed before any later permissive rule can match.
  iptables -A "${CHAIN}" -j REJECT --reject-with icmp-host-prohibited

  # Insert as first INPUT rule.
  iptables -I INPUT 1 -j "${CHAIN}"
}

apply_ipv6_rules() {
  [[ "${ENABLE_IPV6}" == "yes" ]] || return 0

  log "Applico regole IPv6 ${CHAIN}"

  remove_old_chain_v6

  ip6tables -N "${CHAIN}"

  ip6tables -A "${CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A "${CHAIN}" -m conntrack --ctstate INVALID -j DROP
  ip6tables -A "${CHAIN}" -i lo -j ACCEPT
  ip6tables -A "${CHAIN}" -i "${TAILSCALE_IFACE}" -j ACCEPT
  ip6tables -A "${CHAIN}" -p tcp --dport "${SSH_PORT}" -m conntrack --ctstate NEW -j ACCEPT

  if [[ "${ALLOW_TS_DIRECT_PORT}" == "yes" ]]; then
    ip6tables -A "${CHAIN}" -p udp --dport "${TAILSCALE_UDP_PORT}" -j ACCEPT
  fi

  # ICMPv6 is required for healthy IPv6 behavior.
  ip6tables -A "${CHAIN}" -p ipv6-icmp -j ACCEPT

  ip6tables -A "${CHAIN}" -j REJECT --reject-with icmp6-adm-prohibited
  ip6tables -I INPUT 1 -j "${CHAIN}"
}

create_rollback_script() {
  log "Creo rollback automatico tra ${ROLLBACK_DELAY_SECONDS}s se non confermi"

  cat > "${ROLLBACK_SCRIPT}" <<EOF_ROLLBACK
#!/usr/bin/env bash
set -Eeuo pipefail
sleep "${ROLLBACK_DELAY_SECONDS}"
if [[ ! -f "${CONFIRM_FILE}" ]]; then
  iptables-restore < "${LATEST_BACKUP}/iptables.rules"
  if [[ -f "${LATEST_BACKUP}/ip6tables.rules" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
    ip6tables-restore < "${LATEST_BACKUP}/ip6tables.rules"
  fi
fi
EOF_ROLLBACK

  chmod 700 "${ROLLBACK_SCRIPT}"
  nohup "${ROLLBACK_SCRIPT}" >/root/pdm-firewall-rollback.log 2>&1 &
}

install_persistence_tools() {
  if cmd_exists netfilter-persistent; then
    return 0
  fi

  log "Installo netfilter-persistent/iptables-persistent per rendere le regole persistenti"
  env DEBIAN_FRONTEND=noninteractive apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
}

persist_rules() {
  install_persistence_tools
  log "Salvo regole correnti in modo persistente"
  netfilter-persistent save
  systemctl enable netfilter-persistent.service >/dev/null 2>&1 || true
  log "Regole salvate"
}

print_status() {
  echo
  echo "### IPv4 INPUT"
  iptables -S INPUT || true
  echo
  echo "### IPv4 ${CHAIN}"
  iptables -S "${CHAIN}" || true

  if [[ "${ENABLE_IPV6}" == "yes" ]] && cmd_exists ip6tables; then
    echo
    echo "### IPv6 INPUT"
    ip6tables -S INPUT || true
    echo
    echo "### IPv6 ${CHAIN}"
    ip6tables -S "${CHAIN}" || true
  fi

  echo
  echo "### Porte in ascolto"
  ss -tulpn || true
}

apply_rules() {
  require_root
  ensure_tools

  warn "Questo script chiude tutte le porte inbound pubbliche tranne SSH ${SSH_PORT} e, opzionalmente, UDP Tailscale ${TAILSCALE_UDP_PORT}."
  warn "PDM su 8443 resterà raggiungibile via ${TAILSCALE_IFACE}, non da Internet pubblico."
  warn "Mantieni aperta questa sessione SSH e testa una seconda connessione prima di rendere persistente."

  if ! ip link show "${TAILSCALE_IFACE}" >/dev/null 2>&1; then
    warn "Interfaccia ${TAILSCALE_IFACE} non trovata. Lo script prosegue, ma PDM non sarà raggiungibile via Tailscale finché l'interfaccia non esiste."
  fi

  rm -f "${CONFIRM_FILE}"

  backup_rules
  apply_ipv4_rules
  apply_ipv6_rules
  create_rollback_script

  cat <<EOF_APPLY

[OK] Regole applicate temporaneamente.

TEST DA FARE SUBITO, DA UN SECONDO TERMINALE:

  ssh -p ${SSH_PORT} <utente>@<IP_PUBBLICO>
  ssh <utente>@<IP_TAILSCALE>
  curl -kI https://<IP_TAILSCALE_O_DNS_TAILSCALE>:8443

Se tutto funziona, conferma entro ${ROLLBACK_DELAY_SECONDS}s:

  sudo touch ${CONFIRM_FILE}
  sudo $0 persist

Se qualcosa non va:

  sudo $0 rollback

Regole attese:
  - TCP ${SSH_PORT} aperta da pubblico
  - UDP ${TAILSCALE_UDP_PORT} aperta da pubblico solo se ALLOW_TS_DIRECT_PORT=yes
  - tutto il traffico su ${TAILSCALE_IFACE} accettato
  - TCP 8443 NON esposto pubblicamente, ma accessibile via Tailscale

EOF_APPLY

  print_status
}

case "${ACTION}" in
  apply)
    apply_rules
    ;;
  persist)
    require_root
    ensure_tools
    [[ -f "${CONFIRM_FILE}" ]] || die "Conferma mancante: crea prima ${CONFIRM_FILE} dopo aver testato SSH/Tailscale."
    persist_rules
    ;;
  rollback)
    require_root
    ensure_tools
    restore_rules
    ;;
  status)
    require_root
    ensure_tools
    print_status
    ;;
  *)
    cat <<EOF_USAGE
Uso:
  sudo $0 apply
  sudo touch ${CONFIRM_FILE}
  sudo $0 persist
  sudo $0 rollback
  sudo $0 status

Variabili:
  SSH_PORT=22
  TAILSCALE_IFACE=tailscale0
  TAILSCALE_UDP_PORT=41641
  ALLOW_TS_DIRECT_PORT=yes|no
  ALLOW_ICMP=yes|no
  ENABLE_IPV6=yes|no
  ROLLBACK_DELAY_SECONDS=180
EOF_USAGE
    exit 1
    ;;
esac
