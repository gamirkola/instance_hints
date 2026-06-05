# debian_oci_scripts

Script per preparare una piccola istanza Debian su OCI/VPS in vista di Proxmox Datacenter Manager.

Sequenza consigliata:

```bash
chmod +x *.sh
./00_inventory.sh | tee inventory-$(date +%F-%H%M%S).log
CONFIRM_UPGRADE=yes ./01_base_update.sh
NEW_USER=mirko ./02_replace_default_user.sh create
# test login in una seconda sessione
NEW_USER=mirko ./02_replace_default_user.sh verify
NEW_USER=mirko CONFIRM_DISABLE_OLD_USER=yes ./02_replace_default_user.sh disable-old
ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
# test login in seconda sessione, poi:
sudo touch /run/ssh-hardening-confirmed
SWAP_FILE_SIZE_MB=2048 INSTALL_DIAG_TOOLS=1 ./05_resource_cleanup.sh
./06_healthcheck.sh
```

Firewall:

```bash
TRUSTED_CIDR="1.2.3.4/32" ENABLE_PDM_PORT=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
```

Se vuoi temporaneamente SSH da ovunque:

```bash
ALLOW_ANYWHERE=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
```

PDM, solo su Debian Trixie x86_64:

```bash
CONFIRM_PDM_INSTALL=yes ./07_install_pdm_debian.sh
```

Default PDM:

- repository: `pdm-no-subscription`, adatto a test/non produzione;
- package: `proxmox-datacenter-manager-container-meta`, che mantiene il kernel Debian corrente.

Note:

- Non eseguire installazione PDM su Debian diversa da Trixie.
- Su OCI limita sempre la porta 8443 da Security List/NSG a IP/VPN.
- Se lo script firewall rileva regole `InstanceServices`, si ferma per evitare di rompere regole OCI sensibili.
