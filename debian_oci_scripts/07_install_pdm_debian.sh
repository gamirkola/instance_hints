#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# 07_install_pdm_debian.sh
# Installazione Proxmox Datacenter Manager su Debian Trixie.
# Usa di default repository pdm-no-subscription, adatto a test/non produzione.
#
# Uso:
#   CONFIRM_PDM_INSTALL=yes ./07_install_pdm_debian.sh
#
# Repository disponibili:
#   PDM_REPO_COMPONENT=pdm-no-subscription   # default, test/non produzione
#   PDM_REPO_COMPONENT=pdm-test              # più rischioso, solo test feature/bugfix
#   PDM_REPO_COMPONENT=pdm-enterprise        # richiede subscription
#
# Meta package:
#   PDM_META_PACKAGE=proxmox-datacenter-manager-container-meta  # default, mantiene kernel Debian
#   PDM_META_PACKAGE=proxmox-datacenter-manager-meta            # installa kernel Proxmox/ZFS
# ============================================================

CONFIRM="${CONFIRM_PDM_INSTALL:-no}"
PDM_REPO_COMPONENT="${PDM_REPO_COMPONENT:-pdm-no-subscription}"
PDM_META_PACKAGE="${PDM_META_PACKAGE:-proxmox-datacenter-manager-container-meta}"
KEYRING_PATH="/usr/share/keyrings/proxmox-archive-keyring.gpg"
EXPECTED_SHA256="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
EXPECTED_MD5="77c8b1166d15ce8350102ab1bca2fcbf"

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo non disponibile."
    sudo -v
  fi
}

require_debian_trixie() {
  [[ -f /etc/os-release ]] || die "Manca /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "PDM su Debian: sistema rilevato ${PRETTY_NAME:-unknown}, non Debian."
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "Serve Debian Trixie. Rilevato VERSION_CODENAME=${VERSION_CODENAME:-unknown}."
  [[ "$(uname -m)" == "x86_64" ]] || die "PDM richiede x86_64/amd64. Rilevato: $(uname -m)"
}

validate_repo_choice() {
  case "${PDM_REPO_COMPONENT}" in
    pdm-no-subscription)
      warn "Uso pdm-no-subscription: ok per test/non produzione, non raccomandato per produzione."
      ;;
    pdm-test)
      warn "Uso pdm-test: repository di test, più rischioso."
      ;;
    pdm-enterprise)
      warn "Uso pdm-enterprise: richiede subscription valida."
      ;;
    *) die "PDM_REPO_COMPONENT non valido: ${PDM_REPO_COMPONENT}" ;;
  esac
}

validate_package_choice() {
  case "${PDM_META_PACKAGE}" in
    proxmox-datacenter-manager-container-meta)
      log "Userò container-meta: mantiene il kernel Debian corrente e installa set minimo."
      ;;
    proxmox-datacenter-manager-meta)
      warn "Userò meta: può installare kernel Proxmox/ZFS. Più invasivo su cloud."
      ;;
    proxmox-datacenter-manager|proxmox-datacenter-manager-ui)
      warn "Stai installando pacchetti specifici invece del meta-package consigliato."
      ;;
    *) die "PDM_META_PACKAGE non consentito: ${PDM_META_PACKAGE}" ;;
  esac
}

main() {
  require_sudo
  require_debian_trixie
  validate_repo_choice
  validate_package_choice

  if [[ "${CONFIRM}" != "yes" ]]; then
    cat <<EOF
[STOP]
Questo script installerà Proxmox Datacenter Manager su Debian Trixie.
Prima verifica:
  - snapshot/backup boot volume;
  - almeno 1 GiB RAM per valutazione, meglio 4 GiB;
  - almeno 10 GiB liberi, meglio 40 GiB;
  - porta 8443 consentita solo da IP/VPN lato OCI.

Per procedere:
  CONFIRM_PDM_INSTALL=yes ./07_install_pdm_debian.sh

Varianti:
  PDM_REPO_COMPONENT=pdm-test CONFIRM_PDM_INSTALL=yes ./07_install_pdm_debian.sh
  PDM_META_PACKAGE=proxmox-datacenter-manager-meta CONFIRM_PDM_INSTALL=yes ./07_install_pdm_debian.sh
EOF
    exit 1
  fi

  log "Installo prerequisiti"
  ${SUDO} apt-get update
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates wget gnupg debian-archive-keyring

  log "Configuro repository Debian base Trixie se necessario"
  if [[ ! -f /etc/apt/sources.list.d/debian.sources ]]; then
    ${SUDO} tee /etc/apt/sources.list.d/debian.sources >/dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  else
    log "/etc/apt/sources.list.d/debian.sources già presente, non lo sovrascrivo"
  fi

  log "Scarico keyring Proxmox Trixie"
  ${SUDO} wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O "${KEYRING_PATH}"

  log "Verifica hash keyring"
  actual_sha256="$(sha256sum "${KEYRING_PATH}" | awk '{print $1}')"
  actual_md5="$(md5sum "${KEYRING_PATH}" | awk '{print $1}')"
  [[ "${actual_sha256}" == "${EXPECTED_SHA256}" ]] || die "SHA256 keyring non corrisponde: ${actual_sha256}"
  [[ "${actual_md5}" == "${EXPECTED_MD5}" ]] || die "MD5 keyring non corrisponde: ${actual_md5}"

  log "Configuro repository PDM: ${PDM_REPO_COMPONENT}"
  if [[ "${PDM_REPO_COMPONENT}" == "pdm-enterprise" ]]; then
    repo_uri="https://enterprise.proxmox.com/debian/pdm"
  else
    repo_uri="http://download.proxmox.com/debian/pdm"
  fi

  ${SUDO} tee /etc/apt/sources.list.d/proxmox-pdm.sources >/dev/null <<EOF
Types: deb
URIs: ${repo_uri}
Suites: trixie
Components: ${PDM_REPO_COMPONENT}
Signed-By: ${KEYRING_PATH}
EOF

  log "apt update con repository PDM"
  ${SUDO} apt-get update

  log "Installo ${PDM_META_PACKAGE}"
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PDM_META_PACKAGE}"

  log "Verifica servizi PDM"
  systemctl --failed --no-pager || true
  ss -tulpn | grep ':8443' || true

  cat <<'EOF'

[OK] Installazione PDM completata o pacchetti installati.
Accesso web:
  https://IP-OR-HOSTNAME:8443

Nota: limita la porta 8443 lato OCI Security List/NSG a IP/VPN, non a tutto Internet.
EOF
}

main "$@"
