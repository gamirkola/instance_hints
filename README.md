# instance_hints

Script e procedura operativa per preparare una piccola istanza **Ubuntu Server su Oracle Cloud Infrastructure (OCI)**, con l'obiettivo di ottenere una base più sicura, più snella e più controllabile per test e laboratorio.

> **Nota importante**  
> Questa repository **non installa Proxmox Datacenter Manager su Ubuntu**.  
> Proxmox Datacenter Manager (PDM), secondo la documentazione ufficiale, si installa tramite ISO ufficiale oppure sopra una base **Debian Trixie**. Usare repository Debian/Proxmox direttamente su Ubuntu Noble significa mischiare distribuzioni diverse e non è una base supportata o consigliata.

---

## 1. Scopo del progetto

Questi script servono a:

- eseguire un inventario iniziale della VM;
- aggiornare Ubuntu in modo controllato;
- migrare dall'utente cloud di default `ubuntu` a un proprio utente amministrativo;
- copiare le stesse chiavi SSH sull'utente personale;
- disabilitare in modo reversibile l'utente `ubuntu`;
- applicare un hardening SSH prudente e reversibile;
- evitare lockout durante modifiche SSH/firewall;
- alleggerire Ubuntu per una VM con poche risorse;
- aggiungere swap su istanze con poca RAM;
- limitare consumo disco dei log;
- disabilitare servizi inutili, senza toccare componenti OCI critici;
- fornire un healthcheck finale.

Il caso d'uso principale è una VM OCI piccola, per esempio:

- Ubuntu 24.04 LTS;
- circa 1 vCPU;
- circa 1 GiB RAM;
- disco contenuto ma sufficiente;
- accesso SSH tramite chiave;
- firewall OCI gestito tramite Security List o Network Security Group.

---

## 2. Stato della compatibilità PDM

### 2.1 PDM su Debian

La procedura ufficiale alternativa all'ISO è l'installazione sopra **Debian Trixie** tramite repository Proxmox.

Esempio tratto dalla procedura ufficiale:

```bash
cat > /etc/apt/sources.list.d/pdm-test.sources << 'EOF'
# Other repositories will be made available with the first stable releases.
# See https://forum.proxmox.com for announcements.
Types: deb
URIs: http://download.proxmox.com/debian/pdm/
Suites: trixie
Components: pdm-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg
md5sum /usr/share/keyrings/proxmox-archive-keyring.gpg

apt update
apt install proxmox-datacenter-manager proxmox-datacenter-manager-ui
```

Dopo l'installazione, la UI PDM è raggiungibile da:

```text
https://IP-OR-HOSTNAME:8443
```

Login previsto:

```text
root@pam
```

### 2.2 PDM su Ubuntu

Questa repository parte da Ubuntu perché l'istanza OCI disponibile usa Ubuntu. Tuttavia:

- Ubuntu Noble non è Debian Trixie;
- i repository PDM indicano suite `trixie`;
- installare pacchetti Debian Trixie su Ubuntu Noble è una configurazione mista;
- una configurazione mista può rompere dipendenze, aggiornamenti e rollback;
- quindi questa repository **non considera Ubuntu una base ufficialmente supportata per PDM**.

Se l'obiettivo è solo imparare, fare hardening e preparare la VM, Ubuntu va bene.  
Se l'obiettivo è provare PDM in modo coerente con la documentazione, la base corretta resta Debian Trixie o ISO PDM.

---

## 3. Avvertenze specifiche per OCI Ubuntu

OCI applica regole firewall e configurazioni specifiche alle immagini cloud.

Sulle immagini Ubuntu OCI è particolarmente importante:

- non cancellare le regole iptables `InstanceServices`;
- non toccare alla cieca traffico verso `169.254.0.0/16`;
- non disabilitare servizi di rete, boot volume o cloud-init senza sapere esattamente cosa fanno;
- non abilitare UFW automaticamente su Ubuntu OCI;
- gestire l'esposizione delle porte principalmente da Security List o Network Security Group OCI.

Nel caso specifico dell'inventario usato per costruire questa procedura, la VM aveva già regole iptables Oracle con:

```text
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A OUTPUT -d 169.254.0.0/16 -j InstanceServices
```

Questo significa che il firewall host non era completamente aperto: SSH era consentito, il resto veniva rifiutato, e i servizi interni Oracle erano gestiti da catena dedicata.

---

## 4. Regole operative di sicurezza

Prima di modificare SSH, firewall, utenti o kernel:

1. crea snapshot/backup del boot volume da OCI;
2. mantieni aperta la sessione SSH corrente;
3. apri una seconda sessione SSH per testare ogni modifica;
4. verifica che il nuovo utente abbia `sudo` funzionante;
5. non disabilitare l'utente vecchio prima di aver testato il nuovo;
6. non esporre pannelli admin a `0.0.0.0/0`, se non per test temporaneo e consapevole;
7. preferisci Security List/NSG OCI al firewall locale su Ubuntu OCI;
8. non usare UFW su Ubuntu OCI salvo piano esplicito e backup.

---

## 5. Struttura repository

La repository è pensata per poter contenere script diversi in base al tipo di istanza.  
Per questa macchina, gli script sono nella cartella:

```text
ubuntu_oci_scripts/
```

Struttura attuale:

```text
instance_hints/
├── README.md
└── ubuntu_oci_scripts/
    ├── 00_inventory.sh
    ├── 01_base_update.sh
    ├── 03_ssh_hardening_safe.sh
    ├── 04_firewall_base.sh
    ├── 05_resource_cleanup.sh
    ├── 06_healthcheck.sh
    └── 07_replace_default_user.sh
```

### Nota sul vecchio `02_create_admin_user.sh`

Il vecchio script `02_create_admin_user.sh` è considerato **sostituito** da:

```text
07_replace_default_user.sh
```

Motivo: `07_replace_default_user.sh` fa tutto quello che serviva al vecchio `02`, ma in modo più completo:

- crea il nuovo utente amministrativo;
- copia le chiavi SSH dall'utente cloud `ubuntu`;
- copia i gruppi utili;
- configura sudo;
- permette una fase di verifica;
- disabilita `ubuntu` solo dopo conferma esplicita;
- permette eventuale cancellazione definitiva solo come operazione separata.

Quindi nel flusso operativo **non usare più `02_create_admin_user.sh`**.

---

## 6. Sequenza consigliata

### Fase 0 — Preparazione

```bash
cd instance_hints/ubuntu_oci_scripts
chmod +x *.sh
```

Da OCI Console:

- crea backup/snapshot del boot volume;
- verifica Security List/NSG;
- assicurati che la porta SSH sia aperta secondo le tue necessità;
- se lavori da IP dinamico e vuoi accesso temporaneo da ovunque, usa `0.0.0.0/0` solo per SSH e solo finché necessario.

---

### Fase 1 — Inventario

Script:

```bash
./00_inventory.sh | tee inventory-$(date +%F-%H%M%S).log
```

Controlli importanti:

```bash
hostnamectl
uname -a
free -h
df -hT
lsblk
ss -tulpn
systemctl --failed
sudo iptables -S
cloud-init status --long
```

Cosa guardare:

| Area | Cosa verificare |
|---|---|
| Architettura | Per PDM serve x86_64/amd64, non ARM. |
| RAM | Se circa 1 GiB, serve swap. |
| Disco | Almeno 10 GiB liberi per test; meglio 20–40 GiB. |
| Porte | Idealmente solo SSH in ascolto pubblicamente. |
| UFW | Su OCI Ubuntu meglio non usarlo automaticamente. |
| iptables | Non rimuovere `InstanceServices`. |
| cloud-init | Deve risultare `done`. |
| servizi falliti | Deve essere 0 prima di procedere. |

---

### Fase 2 — Aggiornamento base

Script:

```bash
./01_base_update.sh
```

Di default lo script:

- salva un backup della configurazione APT in `/root/pre-hardening-backup/`;
- esegue `apt update`;
- mostra i pacchetti aggiornabili;
- non esegue upgrade senza conferma.

Per applicare gli aggiornamenti:

```bash
CONFIRM_UPGRADE=yes ./01_base_update.sh
```

Dopo l'upgrade:

```bash
systemctl --failed
apt list --upgradable 2>/dev/null
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || true
```

Se è richiesto reboot:

1. verifica backup/snapshot OCI;
2. verifica accesso SSH;
3. riavvia solo dopo questi controlli.

---

### Fase 3 — Migrazione dall'utente `ubuntu` al tuo utente

Script principale:

```bash
NEW_USER=mirko ./07_replace_default_user.sh create
```

Questo script sostituisce il vecchio `02_create_admin_user.sh`.

Lo script:

- crea il nuovo utente se non esiste;
- copia le chiavi SSH da `ubuntu`;
- copia i gruppi secondari utili;
- crea una regola sudoers passwordless, se abilitata;
- blocca la password locale del nuovo utente;
- non disabilita subito `ubuntu`.

Verifica lato script:

```bash
NEW_USER=mirko ./07_replace_default_user.sh verify
```

Poi apri una nuova sessione dal tuo PC:

```bash
ssh mirko@IP_PUBBLICO
whoami
id
sudo -n true && echo "sudo passwordless OK"
sudo hostnamectl
```

Solo dopo aver verificato il nuovo utente:

```bash
NEW_USER=mirko CONFIRM_DISABLE_OLD_USER=yes ./07_replace_default_user.sh disable-old
```

Questa operazione:

- rimuove o rinomina le `authorized_keys` dell'utente vecchio;
- cambia la shell dell'utente vecchio a `/usr/sbin/nologin`, se configurato;
- blocca la password dell'utente vecchio;
- mantiene backup in `/root/pre-hardening-backup/`.

Cancellazione definitiva dell'utente vecchio:

```bash
NEW_USER=mirko CONFIRM_DELETE_OLD_USER=yes ./07_replace_default_user.sh delete-old
```

La cancellazione è distruttiva. Consigliato farla solo dopo:

- login con nuovo utente testato;
- sudo testato;
- almeno un reboot riuscito;
- backup/snapshot disponibile.

---

### Fase 4 — Hardening SSH sicuro

Script:

```bash
ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
```

Lo script applica un drop-in SSH:

```text
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Lo script:

- non cambia la porta SSH;
- verifica `sshd -t`;
- crea backup di `/etc/ssh/sshd_config` e `/etc/ssh/sshd_config.d`;
- ricarica SSH senza riavvio brutale;
- avvia un rollback automatico dopo 180 secondi se non confermi.

Dopo aver testato da una seconda sessione:

```bash
ssh mirko@IP_PUBBLICO
sudo -v
```

Conferma:

```bash
sudo touch /run/ssh-hardening-confirmed
```

Se non confermi, lo script prova a ripristinare la configurazione precedente.

---

### Fase 5 — Firewall

Script:

```bash
TRUSTED_CIDR="1.2.3.4/32" CONFIRM_FIREWALL=yes ./04_firewall_base.sh
```

Per aprire anche la porta PDM 8443:

```bash
TRUSTED_CIDR="1.2.3.4/32" ENABLE_PDM_PORT=yes CONFIRM_FIREWALL=yes ./04_firewall_base.sh
```

Tuttavia, su Ubuntu OCI lo script rileva l'ambiente e si ferma per evitare di abilitare UFW alla cieca.

Per questa VM la scelta consigliata è:

1. non usare UFW;
2. lasciare intatte le regole iptables Oracle;
3. gestire ingress SSH e PDM da OCI Security List o NSG;
4. aprire SSH `22/tcp` secondo necessità;
5. aprire PDM `8443/tcp` solo da IP fidato o VPN.

Valori CIDR comuni:

```text
TUO_IP/32     singolo IP pubblico fidato
0.0.0.0/0     tutto Internet, solo temporaneo e sconsigliato per porte admin
10.0.0.0/24   rete privata OCI, non corrisponde al tuo IP pubblico
```

Se per ora devi accedere da ovunque via SSH, fallo preferibilmente lato OCI con:

```text
Source CIDR: 0.0.0.0/0
Protocol: TCP
Destination port: 22
```

Ma appena possibile restringi a:

```text
Source CIDR: TUO_IP_PUBBLICO/32
Protocol: TCP
Destination port: 22
```

Per PDM evita `0.0.0.0/0` sulla porta `8443`; preferisci IP specifico, VPN o tunnel SSH:

```bash
ssh -L 8443:localhost:8443 mirko@IP_PUBBLICO
```

Poi apri localmente:

```text
https://localhost:8443
```

---

### Fase 6 — Cleanup e ottimizzazione risorse

Script:

```bash
./05_resource_cleanup.sh
```

Per la VM OCI piccola usata come riferimento è consigliata questa esecuzione:

```bash
SWAP_FILE_SIZE_MB=2048 \
INSTALL_DIAG_TOOLS=1 \
DISABLE_SERVICES="rpcbind.service rpcbind.socket ModemManager.service udisks2.service" \
CONFIRM_DISABLE_SERVICES=yes \
./05_resource_cleanup.sh
```

Lo script può:

- installare tool diagnostici opzionali;
- creare swapfile idempotente;
- applicare tuning sysctl leggero;
- limitare journald;
- disabilitare motd-news;
- abilitare fstrim;
- rimuovere snapd solo se confermato;
- disabilitare servizi extra, con lista protetta per componenti critici.

Variabili principali:

| Variabile | Default | Significato |
|---|---:|---|
| `SWAP_FILE_PATH` | `/swapfile` | Percorso swapfile. |
| `SWAP_FILE_SIZE_MB` | `1024` | Dimensione swap in MB. Su 1 GiB RAM meglio `2048`. |
| `VM_SWAPPINESS` | `10` | Riduce uso aggressivo dello swap. |
| `VM_OVERCOMMIT_MEMORY` | `1` | Permette overcommit; utile ma aumenta rischio OOM. |
| `VM_VFS_CACHE_PRESSURE` | `200` | Libera più aggressivamente cache inode/dentry. |
| `DISABLE_ICMP` | `0` | Lascia ping attivo. Non bloccarlo salvo motivo reale. |
| `INSTALL_DIAG_TOOLS` | `0` | Installa `htop`, `iotop`, `sysstat`, `ncdu`. |
| `ENABLE_SYSSTAT` | `0` | Abilita raccolta sysstat/sar. |
| `ENABLE_JOURNAL_LIMITS` | `1` | Limita dimensione log journald. |
| `REMOVE_SNAPD` | `0` | Non rimuove snapd di default. |
| `REMOVE_SNAPD_FORCE` | `0` | Conferma forte per rimozione snapd. |
| `DISABLE_SERVICES` | vuoto | Lista servizi da disabilitare. |
| `CONFIRM_DISABLE_SERVICES` | `no` | Richiesto per disabilitare servizi. |

Servizi da non disabilitare automaticamente:

```text
ssh
cloud-init
systemd-networkd
systemd-resolved
systemd-timesyncd / chrony
open-iscsi / iscsid
multipathd
oracle-cloud-agent
systemd-journald
```

Nel caso OCI Ubuntu, non rimuovere `snapd` se `oracle-cloud-agent` è installato come snap.

Verifica dopo cleanup:

```bash
free -h
swapon --show
df -hT
ss -tulpn
systemctl --failed
sudo iptables -S
journalctl --disk-usage
```

---

### Fase 7 — Healthcheck finale

Script:

```bash
./06_healthcheck.sh
```

Controlla:

- hostname e uptime;
- memoria e swap;
- spazio disco;
- route e indirizzi IP;
- porte in ascolto;
- sintassi SSH;
- stato servizio SSH;
- servizi falliti;
- UFW, se presente;
- iptables;
- DNS;
- HTTPS outbound;
- `apt update`;
- stato cloud-init;
- eventuale reboot richiesto.

Output desiderato:

```text
Swap attivo
Nessun servizio failed
SSH attivo
DNS funzionante
HTTPS outbound funzionante
iptables InstanceServices ancora presente
spazio disco sufficiente
```

---

## 7. Porte e sicurezza di rete

### Porte tipiche

| Porta | Servizio | Esposizione consigliata |
|---:|---|---|
| 22/tcp | SSH | Solo IP fidato o temporaneamente ovunque. |
| 8443/tcp | PDM Web UI | Solo IP fidato, VPN o tunnel SSH. |
| 80/tcp | HTTP | Solo se serve davvero. |
| 443/tcp | HTTPS | Solo se serve davvero. |
| 1883/tcp | MQTT | Non aprire pubblicamente senza TLS/auth/VPN. |

### Accesso da ovunque

Per SSH, `0.0.0.0/0` significa tutto Internet. È accettabile solo se:

- SSH usa solo chiave;
- password login è disabilitato;
- root login è disabilitato;
- fail2ban o equivalente è attivo;
- stai facendo test temporanei.

Per PDM o altri pannelli amministrativi, `0.0.0.0/0` è sconsigliato.

---

## 8. Installazione PDM: se in futuro usi Debian Trixie

Su Debian Trixie, come root:

```bash
cat > /etc/apt/sources.list.d/pdm-test.sources << 'EOF'
# Other repositories will be made available with the first stable releases.
# See https://forum.proxmox.com for announcements.
Types: deb
URIs: http://download.proxmox.com/debian/pdm/
Suites: trixie
Components: pdm-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg

sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg
md5sum /usr/share/keyrings/proxmox-archive-keyring.gpg

apt update
apt install proxmox-datacenter-manager proxmox-datacenter-manager-ui
```

Verifica porta:

```bash
ss -tulpn | grep 8443 || true
```

Accesso:

```text
https://IP-OR-HOSTNAME:8443
```

Utente:

```text
root@pam
```

### Non fare su Ubuntu

Non aggiungere direttamente repository PDM `trixie` su Ubuntu Noble, salvo laboratorio volutamente sperimentale e sacrificabile.

Non eseguire:

```bash
apt install proxmox-datacenter-manager proxmox-datacenter-manager-ui
```

su Ubuntu aspettandoti supporto ufficiale.

---

## 9. Rollback e backup

Gli script salvano backup in:

```text
/root/pre-hardening-backup/
```

Prima di ogni fase rischiosa crea anche snapshot/backup lato OCI.

### Rollback SSH

Se lo script SSH non viene confermato con:

```bash
sudo touch /run/ssh-hardening-confirmed
```

prova automaticamente a ripristinare la configurazione precedente dopo 180 secondi.

### Rollback utente `ubuntu`

Se hai disabilitato `ubuntu` e devi riattivarlo:

```bash
sudo usermod -s /bin/bash ubuntu
sudo passwd -u ubuntu || true
```

Poi ripristina `authorized_keys` dal backup creato in:

```text
/root/pre-hardening-backup/user-migration-*/ubuntu.ssh/authorized_keys
```

Esempio:

```bash
sudo cp /root/pre-hardening-backup/user-migration-*/ubuntu.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys
sudo chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
sudo chmod 600 /home/ubuntu/.ssh/authorized_keys
```

### Rollback servizi disabilitati

Esempio:

```bash
sudo systemctl enable --now rpcbind.service rpcbind.socket
sudo systemctl enable --now ModemManager.service
sudo systemctl enable --now udisks2.service
```

Riabilita solo ciò che ti serve davvero.

---

## 10. Comandi rapidi consigliati

### Sequenza completa prudente

```bash
cd instance_hints/ubuntu_oci_scripts
chmod +x *.sh

./00_inventory.sh | tee inventory-$(date +%F-%H%M%S).log

./01_base_update.sh
CONFIRM_UPGRADE=yes ./01_base_update.sh

NEW_USER=mirko ./07_replace_default_user.sh create
NEW_USER=mirko ./07_replace_default_user.sh verify

ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
# Test da seconda sessione, poi:
sudo touch /run/ssh-hardening-confirmed

NEW_USER=mirko CONFIRM_DISABLE_OLD_USER=yes ./07_replace_default_user.sh disable-old

SWAP_FILE_SIZE_MB=2048 \
INSTALL_DIAG_TOOLS=1 \
DISABLE_SERVICES="rpcbind.service rpcbind.socket ModemManager.service udisks2.service" \
CONFIRM_DISABLE_SERVICES=yes \
./05_resource_cleanup.sh

./06_healthcheck.sh
```

### Solo cleanup leggero

```bash
cd instance_hints/ubuntu_oci_scripts
SWAP_FILE_SIZE_MB=2048 ./05_resource_cleanup.sh
```

### Solo migrazione utente

```bash
cd instance_hints/ubuntu_oci_scripts
NEW_USER=mirko ./07_replace_default_user.sh create
NEW_USER=mirko ./07_replace_default_user.sh verify
NEW_USER=mirko CONFIRM_DISABLE_OLD_USER=yes ./07_replace_default_user.sh disable-old
```

### Solo hardening SSH

```bash
cd instance_hints/ubuntu_oci_scripts
ADMIN_USER=mirko CONFIRM_SSH_HARDENING=yes ./03_ssh_hardening_safe.sh
sudo touch /run/ssh-hardening-confirmed
```

---

## 11. Checklist finale

Prima di considerare la VM pronta:

```bash
free -h
swapon --show
df -hT
ss -tulpn
systemctl --failed
sudo sshd -t
sudo iptables -S
cloud-init status --long
curl -I --max-time 10 https://www.google.com
```

Stato desiderato:

- swap attivo;
- root filesystem con spazio sufficiente;
- nessun servizio fallito;
- SSH funzionante con nuovo utente;
- login password disabilitato;
- `ubuntu` disabilitato o almeno non più usato;
- regole OCI `InstanceServices` intatte;
- UFW non abilitato su Ubuntu OCI;
- porte amministrative filtrate da Security List/NSG;
- PDM eventualmente esposto solo su IP fidato/VPN/tunnel.

---

## 12. Riferimenti ufficiali

- Proxmox Datacenter Manager — Installation: https://pdm.proxmox.com/docs/installation.html
- Proxmox Datacenter Manager — Web UI: https://pdm.proxmox.com/docs/web-ui.html
- Oracle Cloud Infrastructure — Compute best practices: https://docs.oracle.com/en-us/iaas/Content/Compute/References/bestpracticescompute.htm
- Oracle Cloud Infrastructure — Platform images and Ubuntu/UFW warning: https://docs.oracle.com/en-us/iaas/Content/Compute/References/images.htm
- Oracle Cloud Infrastructure — Security rules: https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm
- Oracle Cloud Infrastructure — Network Security Groups: https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/networksecuritygroups.htm
- Ubuntu Server — Automatic updates: https://ubuntu.com/server/docs/how-to/software/automatic-updates/

---

## 13. Nota finale

Questa repository prepara una piccola VM Ubuntu OCI in modo prudente. Non trasforma Ubuntu in Debian e non rende ufficialmente supportata l'installazione PDM su Ubuntu.

Per un laboratorio pulito PDM, la strada corretta resta:

1. Debian Trixie;
2. repository PDM ufficiale;
3. porta 8443 protetta;
4. snapshot/backup prima di ogni modifica importante.