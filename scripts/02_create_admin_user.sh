#!/usr/bin/env bash

#USAGE ADMIN_USER=mirko ./02_create_admin_user.sh
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-}"

if [[ -z "${ADMIN_USER}" ]]; then
  echo "[ERRORE] Devi specificare ADMIN_USER. Esempio:"
  echo "  ADMIN_USER=mirko ./02_create_admin_user.sh"
  exit 1
fi

if [[ "${ADMIN_USER}" == "root" ]]; then
  echo "[ERRORE] Non usare root come ADMIN_USER."
  exit 1
fi

echo "[INFO] Creo/verifico utente admin: ${ADMIN_USER}"

if id "${ADMIN_USER}" >/dev/null 2>&1; then
  echo "[INFO] Utente già esistente."
else
  sudo adduser --disabled-password --gecos "" "${ADMIN_USER}"
fi

echo "[INFO] Aggiungo ${ADMIN_USER} al gruppo sudo"
sudo usermod -aG sudo "${ADMIN_USER}"

SOURCE_HOME="${HOME}"
TARGET_HOME="$(eval echo "~${ADMIN_USER}")"

echo "[INFO] Preparo directory .ssh"
sudo install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${TARGET_HOME}/.ssh"

if [[ -f "${SOURCE_HOME}/.ssh/authorized_keys" ]]; then
  echo "[INFO] Copio authorized_keys dall'utente corrente"
  sudo cp "${SOURCE_HOME}/.ssh/authorized_keys" "${TARGET_HOME}/.ssh/authorized_keys"
  sudo chown "${ADMIN_USER}:${ADMIN_USER}" "${TARGET_HOME}/.ssh/authorized_keys"
  sudo chmod 600 "${TARGET_HOME}/.ssh/authorized_keys"
else
  echo "[WARN] Nessun authorized_keys trovato in ${SOURCE_HOME}/.ssh/"
  echo "[WARN] Aggiungi manualmente la tua chiave pubblica in:"
  echo "       ${TARGET_HOME}/.ssh/authorized_keys"
fi

echo "[INFO] Blocco password locale dell'utente: login solo chiave se SSH lo consente"
sudo passwd -l "${ADMIN_USER}" || true

echo
echo "[VERIFICA OBBLIGATORIA]"
echo "Apri un secondo terminale e prova:"
echo "  ssh ${ADMIN_USER}@<IP_PUBBLICO>"
echo "  sudo -v"
echo
echo "[OK] Utente admin preparato."