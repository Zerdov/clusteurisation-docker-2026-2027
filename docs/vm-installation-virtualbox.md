# Installation des VM — lab local VirtualBox

Ce document décrit le lab local monté sous VirtualBox (poste personnel), séparé de l'environnement Proxmox décrit dans [vm-installation.md](vm-installation.md). Différences principales : 4 VM au lieu de 3 (le registry est une VM à part, hors Swarm), réseau à deux cartes par VM (NAT + Host-only) au lieu d'une seule carte sur le VNet de l'école, et `ifupdown` (`/etc/network/interfaces.d/`) au lieu de `netplan` — l'image Proxmox est un template cloud-init qui embarque netplan, un Debian netinst classique ne l'a pas par défaut.

## 1. Topologie

| Rôle | Hostname | IP Host-only | Utilisateur Linux |
|---|---|---|---|
| Registry (hors Swarm) | `cluster-swarm-registry` | `192.168.56.10` | `registry` |
| Manager | `cluster-swarm-manager` | `192.168.56.11` | `manager` |
| Worker 1 | `cluster-swarm-worker1` | `192.168.56.12` | `worker` |
| Worker 2 | `cluster-swarm-worker2` | `192.168.56.13` | `worker` |

`worker1` et `worker2` partagent le même nom d'utilisateur (`worker`) — seuls le hostname et l'IP les distinguent. `.1` sur `192.168.56.0/24` est pris par l'adaptateur virtuel Host-only de l'hôte Windows, à ne jamais attribuer à une VM.

Décision actée (voir historique Git des commits `3e8a1d8`/`2a60e84`/`ada8227` pour le contexte : le dépôt était passé d'un registry sur 4ᵉ VM à un registry en service Swarm sur le manager le 2026-10-06, puis revient ici à la version 4 VM) : le registry tourne en dehors du Swarm, sur sa propre VM. Ça rend `swarm/stack.registry.yml` obsolète au profit de `registry/compose.yml` — **le déploiement (scripts, `daemon.json`, pare-feu) reste à aligner, voir section 9.**

## 2. Réseau — deux cartes par VM

Chaque VM a deux adaptateurs réseau VirtualBox, configurés sur le gabarit avant le premier clonage (un clone hérite du réglage de ses cartes) :

- **Adaptateur 1 = NAT** : sortie Internet (apt, docker pull), DHCP automatique. Volontairement NAT et pas Bridged : le bridging sur Wi-Fi est documenté comme peu fiable par VirtualBox (la plupart des cartes Wi-Fi ne supportent pas le mode promiscuous), et NAT ne dépend pas du réseau physique où se trouve le PC.
- **Adaptateur 2 = Host-only Adapter** (`VirtualBox Host-Only Ethernet Adapter`, réseau `192.168.56.0/24`) : réseau privé entre les 4 VM et l'hôte, IP fixe posée manuellement sur chaque clone.

Côté invité, `enp0s3` = NAT (DHCP), `enp0s8` = Host-only (statique). Noms à vérifier avec `ip -br a` si l'ordre diffère.

### Fichiers `ifupdown`

```
# /etc/network/interfaces.d/enp0s3
auto enp0s3
iface enp0s3 inet dhcp
```

```
# /etc/network/interfaces.d/enp0s8
auto enp0s8
iface enp0s8 inet static
    address 192.168.56.1X   # .10 registry, .11 manager, .12 worker1, .13 worker2
    netmask 255.255.255.0
```

Aucune route par défaut sur `enp0s8` — elle doit rester celle fournie par `enp0s3` (NAT), sinon deux routes par défaut se disputent la sortie Internet.

### Piège découvert : `ifupdown` source par contenu, pas par nom de fichier

`source /etc/network/interfaces.d/*` dans `/etc/network/interfaces` charge **tous** les fichiers du dossier et identifie chaque interface par la ligne `iface NOM ...` qu'il contient, pas par le nom du fichier. Lors d'un copier-coller croisé, le contenu d'`enp0s8` (`iface enp0s8 inet static ... address 192.168.56.11`) s'est retrouvé écrit dans le fichier *nommé* `enp0s3` sur le manager. Résultat : `enp0s8` recevait deux adresses à la fois (`.11` fantôme en plus de la bonne), et `enp0s3` restait à `DOWN` puisqu'aucun fichier ne déclarait réellement `iface enp0s3 ...`. Le bug s'est propagé à `registry` (cloné depuis le manager) mais pas aux workers (clonés depuis `worker1`, déjà corrigé entre-temps).

**Vérification systématique après tout clonage ou édition manuelle :**

```bash
cat /etc/network/interfaces.d/enp0s3   # doit contenir "iface enp0s3 inet dhcp"
cat /etc/network/interfaces.d/enp0s8   # doit contenir "iface enp0s8 inet static" + la bonne IP
```

### Piège : désynchronisation de l'état `ifupdown`

Après un `ip addr flush` / édition manuelle, `ifup`/`ifdown` peuvent se contredire (`not configured` d'un côté, `Address already assigned` de l'autre) parce que `/run/network/ifstate` ne reflète plus l'état réel du noyau. Remède fiable :

```bash
sudo ip addr flush dev enp0s8
sudo ip link set enp0s8 down
sudo ip link set enp0s8 up
sudo ifup --force enp0s8
ip -br a
```

Un message `Error: ipv4: Address already assigned` peut apparaître mais être sans conséquence si l'état final (`ip -br a`) est correct — vérifier le résultat, pas seulement l'absence d'erreur.

## 3. Installation Debian

ISO netinst amd64, dernière stable (`cdimage.debian.org/debian-cd/current/amd64/iso-cd/`). À la question du clavier dans l'installeur, choisir **France** (AZERTY). Au `tasksel`, cocher uniquement **SSH server** + **standard system utilities** — **décocher Debian desktop environment** : un environnement de bureau s'est installé par erreur sur le gabarit initial et a causé les deux problèmes ci-dessous.

### SSH absent ou inactif

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

### `sudo` non configuré

Debian n'ajoute le premier utilisateur créé au groupe `sudo` **que si le mot de passe root est laissé vide** à l'installation. Mot de passe root défini → ajout manuel nécessaire, en root (`su -`) :

```bash
usermod -aG sudo <user>
```

Se reconnecter ensuite (nouvelle session) pour que le nouveau groupe soit pris en compte.

### Mot de passe root perdu / incohérent

Cause probable : mot de passe tapé en AZERTY pendant que la console utilisait encore le clavier QWERTY par défaut (avant configuration de `keyboard-configuration`). Récupération via GRUB :

1. Redémarrer, maintenir **Shift** pour afficher le menu GRUB.
2. `e` sur l'entrée Debian, ajouter `rw init=/bin/bash` à la fin de la ligne `linux`.
3. `Ctrl+X` pour démarrer.
4. `mount -o remount,rw /`
5. `passwd root` — **utiliser uniquement des lettres minuscules et des chiffres**, pour rester indépendant du layout clavier actif à ce moment-là.
6. `usermod -aG sudo <user>` si besoin au passage.
7. `exec /sbin/init`

## 4. Clavier AZERTY

```bash
sudo dpkg-reconfigure keyboard-configuration   # Country of origin + layout = French
sudo service keyboard-setup restart
sudo loadkeys fr                               # effet immédiat sur la session en cours
```

Sans config française, la console reste en QWERTY : `/` est à la position du `!` AZERTY, `'` à la position du `ù` AZERTY (mapping par position physique de touche, pas par symbole imprimé).

## 5. Renommer l'utilisateur Linux

Pour aligner le nom d'utilisateur sur le rôle (`manager`/`worker`/`registry` au lieu du nom hérité du gabarit à chaque clonage) :

**Blocage attendu** : `usermod -l` refuse de renommer un utilisateur qui a un process actif — y compris la session SSH courante elle-même. Pire, si des paquets desktop/audio sont installés (voir section 6), **toute connexion** (SSH y compris, pas seulement un login graphique) fait démarrer une instance `systemd --user` avec `dbus-daemon`/`pipewire`/`wireplumber`, qui bloque aussi le renommage. Procédure fiable :

```bash
# 1. Depuis la session à renommer, autoriser temporairement root par mot de passe
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# 2. Fermer complètement cette session (pas juste "exit" d'un sous-shell)

# 3. Se connecter en root, depuis une connexion neuve
ssh root@<IP>

# 4. Nettoyer les process résiduels
ps -u <ancien_nom>
loginctl terminate-user <ancien_nom>

# 5. Renommer
usermod -l <nouveau_nom> <ancien_nom>
usermod -m -d /home/<nouveau_nom> <nouveau_nom>
groupmod -n <nouveau_nom> <ancien_nom>

# 6. Refermer SSH root par mot de passe
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh
```

Le groupe `sudo` suit l'UID, pas le nom — aucune réinscription nécessaire après renommage.

## 6. Purge de l'environnement de bureau

Un environnement de bureau (GDM3/GNOME + pipewire/wireplumber) s'est retrouvé installé sur le gabarit initial, sans utilité sur un nœud de cluster piloté en SSH, et source directe du blocage de la section 5. **L'autologin GDM n'était pas la cause** (`AutomaticLoginEnable` est commenté par défaut dans `/etc/gdm3/daemon.conf`) — la vraie cause est que ces paquets enregistrent des services utilisateur systemd démarrés à toute connexion, graphique ou SSH.

Sur chaque VM :

```bash
dpkg -l | grep -iE 'gnome|gdm|pipewire|wireplumber|task-'
sudo apt purge -y gdm3 gnome-core gnome-session pipewire wireplumber '~ngnome'
sudo apt autoremove -y --purge
sudo reboot
```

Vérifier après reboot et reconnexion :

```bash
ps -u $(whoami)   # ne doit plus montrer que sshd-session/bash
```

## 7. Clonage

Dans l'assistant de clonage VirtualBox :
- **Clone Intégral** (pas lié) : indépendance totale du gabarit, peut être supprimé ensuite sans casser les clones.
- **MAC Address Policy = "Inclure uniquement les adresses MAC de l'interface réseau NAT"** (réglage par défaut) : conserve la MAC du NAT (sans risque, chaque VM a son NAT isolé) et régénère une nouvelle MAC pour l'adaptateur Host-only — évite les collisions sur le réseau partagé `192.168.56.0/24`.
- **Keep Hardware UUIDs décoché** : évite un UUID matériel dupliqué entre clones.

### Nettoyage pré-clonage — à refaire avant CHAQUE clonage, pas une seule fois

Le `machine-id` se régénère à chaque reboot une fois vidé — si la VM source a rebooté depuis le dernier nettoyage, revider avant de cloner à nouveau :

```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo poweroff
```

Ne jamais supprimer `/etc/ssh/ssh_host_*` (sinon `sshd` refuse de redémarrer sur le clone).

Après clonage, sur chaque clone : hostname (`hostnamectl set-hostname ...`), IP statique sur `enp0s8` (section 2), `/etc/hosts` (la ligne `127.0.1.1` garde l'ancien hostname tant qu'elle n'est pas éditée à la main — sinon `sudo` affiche un avertissement de résolution inoffensif mais bruyant), puis reboot de validation (persistance réseau + SSH) avant de considérer la VM prête.

## 8. Stockage

20 Go par VM (VDI, allocation dynamique — ne consomme sur le disque hôte que ce qui est réellement utilisé). La VM `registry` a été clonée à 20 Go également (pas de redimensionnement effectué), alors qu'elle est la seule à accumuler toutes les couches d'images poussées sans garbage collection automatique. Compromis accepté : purge manuelle régulière à prévoir (`docker system prune`, GC du registry) plutôt que redimensionnement du disque.

## 9. Reste à faire avant déploiement

Le provisionnement des 4 VM est terminé ; le déploiement applicatif est reporté. Pour la prochaine session :

- `registry/compose.yml` à déployer sur `cluster-swarm-registry` (htpasswd via `scripts/registry-auth.sh`, volume de données, pare-feu `ufw` restreignant le port 5000 à `192.168.56.0/24`).
- `daemon.json` sur manager/worker1/worker2 : `insecure-registries` doit pointer vers `192.168.56.10:5000`, pas vers le manager.
- `scripts/vm-up.sh`, `scripts/lib/lab.sh`, `scripts/add-service.sh` supposent encore un registry colocalisé sur le manager (`swarm/stack.registry.yml`, `REG_HOTE=$MANAGER_IP:5000`) — à réaligner sur la topologie à 4 VM avant toute utilisation sur ce lab.
- Initialisation du Swarm (`docker swarm init` sur le manager, `join` des deux workers), toujours à faire.
