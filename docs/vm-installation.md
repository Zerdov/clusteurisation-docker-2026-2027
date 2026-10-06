# Installation des VM Nebula

Ce document décrit comment préparer les machines virtuelles du cluster (un manager, deux workers), du modèle jusqu'aux clones. Il reprend les pièges rencontrés et les solutions retenues. Il est écrit pour être suivi dans l'ordre.

## 1. Topologie

| Rôle | Nom d'hôte | IP | Remarque |
|---|---|---|---|
| Manager (et registry) | `clusteurisation-docker-manager` | `10.96.238.1` | Leader Swarm, registry en service Swarm |
| Worker 1 | `clusteurisation-docker-worker1` | `10.96.238.2` | Étiqueté `tier=data` (base, bus) |
| Worker 2 | `clusteurisation-docker-worker2` | `10.96.238.3` | Étiqueté `tier=app` |
| Passerelle | routeur OpenWrt de l'étudiant | `10.96.238.254` | NAT vers le WAN |

Les VM sont sur le VNet personnel de l'étudiant (`vn1006` dans Proxmox). Toutes les VM doivent être sur **le même** VNet que le routeur OpenWrt : c'est ce qui permet à l'ARP vers `10.96.238.254` de répondre.

## 2. Accès SSH

Les VM ne sont joignables que via le rebond de l'école. Authentification par clé uniquement.

Sur le poste de travail, dans `~/.ssh/config` :

```
Host 10.210.0.19
    User root

Host 10.96.238.*
    User manager
    ProxyJump root@10.210.0.19
    IdentityFile ~/.ssh/id_ed25519
```

Vérification (doit répondre sans mot de passe) :

```bash
ssh -o BatchMode=yes manager@10.96.238.1 'hostname'
```

`BatchMode=yes` fait échouer la commande si une clé manque, ce qui correspond à la condition de `scripts/vm-up.sh`.

## 3. Préparer le modèle (template)

À faire **une seule fois**, sur la VM qui servira de modèle. Ne pas initialiser de Swarm sur le modèle.

### 3.1 Réseau

Le clone hérite du bridge de build de la template. Dans Proxmox, pour la carte réseau (`net0`) : bridge = `vn1006` (le VNet de l'étudiant), modèle VirtIO.

Route par défaut persistante, dans un fichier séparé de `50-cloud-init.yaml` (géré par cloud-init, qui peut le réécrire au démarrage) :

```yaml
# /etc/netplan/60-default-route.yaml
network:
  version: 2
  ethernets:
    eth0:
      routes:
        - to: default
          via: 10.96.238.254
```

```bash
sudo chmod 600 /etc/netplan/60-default-route.yaml
sudo netplan try
```

Vérifier qu'il n'y a **qu'une** route par défaut : `ip route` doit afficher une seule ligne `default via 10.96.238.254`. Si `50-cloud-init.yaml` contient aussi un `gateway4:` pour `eth0`, le supprimer.

### 3.2 Docker

Installation depuis le dépôt officiel Docker, documentée à `docs.docker.com/engine/install/debian` (vérifier la procédure en vigueur : elle évolue).

Avant de faire confiance à la clé du dépôt, vérifier son empreinte :

```bash
sudo gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc
```

Comparer à l'empreinte publiée dans la doc Docker. Ne pas continuer si elles diffèrent.

Droits Docker sans sudo :

```bash
sudo usermod -aG docker $USER
# puis se reconnecter
docker ps
```

### 3.3 Configuration du démon Docker

`/etc/docker/daemon.json` :

```json
{
  "mtu": 1350,
  "default-address-pools": [ { "base": "172.30.0.0/16", "size": 24 } ],
  "insecure-registries": ["10.96.238.1:5000"],
  "dns": ["10.96.238.254"]
}
```

- **`mtu: 1350`** : le lien passe par le VXLAN du SDN, dont le MTU effectif est inférieur à 1500. Avec 1500, les gros paquets sont perdus sans erreur (petites requêtes OK, gros transferts bloqués). La valeur est héritée du bridge (`Same as bridge` dans Proxmox).
- **`default-address-pools`** : évite que Docker prenne des sous-réseaux `10.x` qui entreraient en collision avec le réseau du lab.
- **`insecure-registries`** : le registry est en HTTP sur le manager. À adapter si le registry passe en HTTPS.
- **`dns`** : les conteneurs ne doivent pas utiliser le DNS de l'école (`10.255.0.2`), qui ne résout pas les noms externes depuis un conteneur (`bad address` sur `registry.npmjs.org`). Le DNS du routeur (`10.96.238.254`) le fait, vérifié avec `docker run --rm --dns 10.96.238.254 node:24-alpine ...`.

Appliquer :

```bash
sudo systemctl restart docker
```

## 4. Nettoyage du modèle avant clonage

Le modèle ne doit contenir **aucun** état propre à une VM :

```bash
docker swarm leave --force          # s'il y a un Swarm
sudo systemctl stop docker
sudo rm -rf /var/lib/docker/swarm   # état Swarm local
sudo rm -f /etc/docker/key.json     # identité du moteur Docker
sudo truncate -s 0 /etc/machine-id  # identité systemd (regénérée au démarrage)
sudo rm -f /var/lib/dbus/machine-id
sudo systemctl start docker
```

Éteindre la VM, puis la cloner dans Proxmox (trois clones : manager, worker1, worker2).

**Ne pas supprimer `/etc/ssh/ssh_host_*`** : sans ces clés, `sshd -t` échoue et le service ne démarre plus (`Start request repeated too quickly`). Sur les clones, si ssh ne démarre pas, la correction est `sudo ssh-keygen -A && sudo systemctl restart ssh`.

Sans ce nettoyage, les trois clones partagent l'identité du moteur et l'état Swarm, et le cluster ne peut pas se former correctement.

## 5. Configuration de chaque clone

Pour chaque clone, à la console Proxmox ou en SSH :

1. **Nom d'hôte** :
   ```bash
   sudo hostnamectl set-hostname clusteurisation-docker-worker1
   ```
2. **Adresse IP fixe** dans `/etc/netplan/50-cloud-init.yaml` (ou via un fichier dédié, pour éviter qu'une réécriture de cloud-init ne l'écrase) : `10.96.238.1`, `.2` ou `.3`, selon le rôle.
3. **Appliquer et vérifier** :
   ```bash
   sudo netplan try
   ip -br a && ip route
   ```
4. **Carte réseau Proxmox** : bridge `vn1006`, vérifié dans la configuration de la VM.
5. **Vérifier l'accès** depuis le poste : `ssh -o BatchMode=yes manager@<IP> hostname` doit répondre sans mot de passe.

Le routeur OpenWrt répond à l'ARP de `10.96.238.254` uniquement si la VM est sur le bon VNet. C'est le premier test à faire si une VM ne sort pas vers Internet.

## 6. Vérifications à chaque étape

```bash
ip route                            # une seule route par défaut, via 10.96.238.254
ping -c2 1.1.1.1                    # sortie vers Internet
resolvectl query deb.debian.org     # DNS
sudo apt update                     # dépôts accessibles
docker info --format 'Swarm: {{.Swarm.LocalNodeState}}'   # inactive avant init
docker info --format '{{.Server.Version}}'
```

Points normaux à ne pas confondre avec une panne :
- `docker0` est `linkdown` tant qu'aucun conteneur ne tourne.
- `10.255.0.2 FAILED` dans la table ARP : un DNS hors sous-réseau, joint via la passerelle.

## 7. Initialisation du Swarm

Sur le manager uniquement :

```bash
docker swarm init --advertise-addr 10.96.238.1
docker swarm join-token worker     # commande à exécuter sur les workers
```

Sur chaque worker :

```bash
docker swarm join --token <jeton> 10.96.238.1:2377
```

Labels de placement (sur le manager) :

```bash
docker node update --label-add tier=data clusteurisation-docker-worker1
docker node update --label-add tier=app  clusteurisation-docker-worker2
```

Vérification : `docker node ls` doit afficher trois nœuds `Ready`, un `Leader`.

## 8. Registry

**Statut : à valider.** Le registry tourne comme service Swarm sur le manager, sur le port 5000 publié (`mode: host`), car les démons Docker des workers doivent pouvoir le joindre par HTTP. Ce port publié est un écart à l'exigence « un seul port publié » : il doit être restreint par pare-feu au sous-réseau `10.96.238.0/24`.

Décisions et étapes restantes :
- valider la publication du port 5000 et sa restriction ufw ;
- écrire le stack `swarm/stack.registry.yml` (contrainte `node.role == manager`, volume local, identifiants htpasswd) ;
- ajouter le déploiement du registry à `scripts/vm-up.sh`, avant le push des images ;
- mettre à jour `CHOIX.md` (la section Versions indique aujourd'hui « registry hors du cluster »).

## 9. Points de vigilance

- **Cloud-init peut réécrire netplan** : la route et l'IP vivent dans des fichiers séparés (`60-...`), jamais dans `50-cloud-init.yaml` seul.
- **Un clone reprend le bridge du modèle** : toujours vérifier `vn1006` après clonage.
- **Un Swarm initialisé avant le `daemon.json`** garde ses réseaux avec les anciens réglages : quitter le Swarm (`docker swarm leave --force`) avant de corriger le démon, puis réinitialiser.
- **La clé SSH du rebond doit être dans `~/.ssh/authorized_keys` du rebond et des VM** : sinon `vm-up.sh` (mode `BatchMode`) échoue.
