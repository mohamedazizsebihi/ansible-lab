# Ansible Lab — Infrastructure AWS automatisée (ISOSET)

Projet d'automatisation complet avec **Ansible** : il crée une petite infrastructure sur **AWS EC2**, puis la configure entièrement (utilisateurs, serveurs web Nginx, base de données MariaDB, stockage LVM, tâches planifiées), et enfin la détruit proprement.

Tout est **idempotent** : relancer un playbook ne change rien si l'état voulu est déjà atteint.

---

## Sommaire

1. [Architecture](#architecture)
2. [Structure du projet](#structure-du-projet)
3. [Prérequis](#prérequis)
4. [Installation](#installation)
5. [Utilisation pas à pas](#utilisation-pas-à-pas)
6. [Détail des playbooks](#détail-des-playbooks)
7. [Les rôles](#les-rôles)
8. [Inventaire dynamique](#inventaire-dynamique)
9. [Gestion des secrets (Ansible Vault)](#gestion-des-secrets-ansible-vault)
10. [Vérifications](#vérifications)
11. [Destruction de l'infrastructure](#destruction-de-linfrastructure)
12. [Choix techniques et bonnes pratiques](#choix-techniques-et-bonnes-pratiques)
13. [Dépannage](#dépannage)

---

## Architecture

```
                    ┌──────────────────────────────┐
                    │   Poste de contrôle (WSL)    │
                    │   Ansible + boto3 + AWS CLI  │
                    └──────────────┬───────────────┘
                                   │  API AWS (provision / destroy)
                                   │  SSH port 22 (configuration)
                                   ▼
   ┌──────────────────── AWS eu-north-1 — VPC par défaut ────────────────────┐
   │                       Security group : exam-sg                          │
   │      SSH 22 ← uniquement mon IP publique   |   HTTP 80 ← tout le monde  │
   │                                                                         │
   │   ┌───────────┐     ┌───────────┐              ┌───────────────────┐    │
   │   │   web1    │     │   web2    │              │       db1         │    │
   │   │  Nginx    │     │  Nginx    │              │  MariaDB 10.5     │    │
   │   │  /health  │     │  /health  │              │  + disque EBS 2Go │    │
   │   │  cron     │     │  cron     │              │  LVM → /backup    │    │
   │   └───────────┘     └───────────┘              └───────────────────┘    │
   │       groupe [web]                                  groupe [db]         │
   │   └────────────────────── groupe parent [prod] ──────────────────────┘  │
   └─────────────────────────────────────────────────────────────────────────┘
```

| Instance | Rôle (tag `Role`) | Type      | OS                 | Particularité                       |
|----------|-------------------|-----------|--------------------|-------------------------------------|
| `web1`   | `web`             | t3.micro  | Amazon Linux 2023  | Nginx + page d'accueil + `/health`  |
| `web2`   | `web`             | t3.micro  | Amazon Linux 2023  | Nginx + page d'accueil + `/health`  |
| `db1`    | `db`              | t3.micro  | Amazon Linux 2023  | MariaDB + volume EBS gp3 de 2 Go    |

Toutes les ressources portent le tag `Project: ansible-exam`, ce qui permet à l'inventaire dynamique de les retrouver et à `destroy.yml` de ne supprimer **que** celles-ci.

---

## Structure du projet

```
ansible-exam/
├── ansible.cfg              # Configuration Ansible (inventaire, clé SSH, vault, pipelining…)
├── requirements.yml         # Collections Ansible nécessaires
├── adhoc.sh                 # Commandes ad hoc (paquets, motd, répertoire)
│
├── provision.yml            # 1. Crée l'infrastructure AWS
├── site.yml                 # 2. Playbook maître : configure tous les serveurs
│   ├── users.yml            #    Utilisateurs, groupes et sudo
│   ├── web.yml              #    Serveurs web (rôle webserver)
│   ├── db.yml               #    Base de données (rôle database)
│   ├── storage.yml          #    Stockage LVM sur db1
│   ├── facts.yml            #    Facts et rapports (reports/<hôte>.txt)
│   └── cron.yml             #    Tâche planifiée de health-check
├── destroy.yml              # 3. Détruit l'infrastructure AWS
│
├── inventory/
│   ├── aws_ec2.yml          # Inventaire dynamique (plugin amazon.aws.aws_ec2)
│   └── groups               # Déclaration des groupes web, db et prod:children
│
├── vars/
│   ├── aws.yml              # Région, type d'instance, clé, security group, liste des instances
│   └── users.yml            # Liste des utilisateurs (alice, bob, carol)
│
├── group_vars/all/
│   ├── vars.yml             # Variables "propres" qui pointent vers le vault
│   └── vault.yml            # Secrets chiffrés avec Ansible Vault (AES256)
│
└── roles/
    ├── webserver/           # Nginx, page d'accueil, endpoint /health
    └── database/            # MariaDB, base examdb, utilisateur appuser
```

---

## Prérequis

### Sur le poste de contrôle

- Linux ou **WSL** (Ubuntu)
- **Python 3** avec **boto3** et **botocore** (utilisés par les modules `amazon.aws`)
- **Ansible** (ansible-core ≥ 2.15 recommandé)
- **AWS CLI** configuré avec un profil nommé `isoset`

```bash
pip install ansible boto3 botocore
aws configure --profile isoset                 # Access key, secret key, région eu-north-1
aws sts get-caller-identity --profile isoset   # Vérifie que les identifiants fonctionnent
```

### Clé SSH

Une paire de clés doit exister sur le poste :

| Fichier                     | Usage                                                          |
|-----------------------------|----------------------------------------------------------------|
| `~/.ssh/isoset-lab.pub`     | Clé **publique**, importée dans AWS par `provision.yml`         |
| `~/.ssh/isoset-lab.pem`     | Clé **privée**, utilisée par Ansible pour se connecter en SSH   |

Pour la générer si besoin :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/isoset-lab -N ""
mv ~/.ssh/isoset-lab ~/.ssh/isoset-lab.pem
chmod 600 ~/.ssh/isoset-lab.pem
```

### Compte AWS

L'utilisateur IAM du profil `isoset` doit avoir les droits EC2 (instances, AMI, key pairs, security groups, lecture des VPC).

---

## Installation

```bash
# 1. Cloner le dépôt
git clone https://github.com/mohamedazizsebihi/ansible-lab.git
cd ansible-lab

# 2. Installer les collections Ansible dans ./collections
ansible-galaxy collection install -r requirements.yml -p ./collections

# 3. Créer le fichier du mot de passe Vault (jamais commité, voir .gitignore)
echo 'VOTRE_MOT_DE_PASSE_VAULT' > .vault-pass
chmod 600 .vault-pass
```

Collections utilisées (`requirements.yml`) :

| Collection          | Modules utilisés                                     |
|---------------------|------------------------------------------------------|
| `amazon.aws`        | `ec2_instance`, `ec2_key`, `ec2_security_group`, `ec2_ami_info`, `ec2_vpc_net_info`, plugin d'inventaire `aws_ec2` |
| `community.general` | `lvg`, `lvol`, `filesystem`                          |
| `ansible.posix`     | `mount`                                              |
| `community.mysql`   | `mysql_db`, `mysql_user`                             |

---

## Utilisation pas à pas

```bash
# Étape 1 — Créer l'infrastructure sur AWS
ansible-playbook provision.yml

# Étape 2 — Vérifier que l'inventaire dynamique voit les 3 machines
ansible-inventory --graph
ansible all -m ping

# Étape 3 — Configurer tous les serveurs
ansible-playbook site.yml

# (optionnel) Ne lancer qu'une partie grâce aux tags
ansible-playbook site.yml --tags web
ansible-playbook site.yml --tags users,cron

# (optionnel) Commandes ad hoc
./adhoc.sh

# Étape 4 — Tout supprimer à la fin
ansible-playbook destroy.yml
```

Sortie attendue de `ansible-inventory --graph` :

```
@all:
  |--@ungrouped:
  |--@aws_ec2:
  |  |--web1
  |  |--web2
  |  |--db1
  |--@prod:
  |  |--@web:
  |  |  |--web1
  |  |  |--web2
  |  |--@db:
  |  |  |--db1
```

---

## Détail des playbooks

### `provision.yml` — Création de l'infrastructure

S'exécute sur `localhost` (`connection: local`) : il parle à l'**API AWS**, pas en SSH. La région et le profil `isoset` sont injectés dans tous les modules AWS via `module_defaults`.

1. **Détecte l'IP publique** du poste via `https://api.ipify.org`.
2. **Importe la clé publique** `~/.ssh/isoset-lab.pub` dans EC2 sous le nom `ansible-exam`.
3. **Récupère le VPC par défaut** de la région.
4. **Crée le security group `exam-sg`** :
   - SSH (22) ouvert **uniquement** à l'IP détectée (`/32`) ;
   - HTTP (80) ouvert à tous.
5. **Cherche la dernière AMI Amazon Linux 2023 x86_64** (tri par `creation_date`).
6. **Crée les 3 instances** définies dans `vars/aws.yml` :
   - idempotent grâce au tag `Name` ;
   - `db1` reçoit un volume EBS supplémentaire (`/dev/sdf`, 2 Go, gp3) ;
   - **IMDSv2 obligatoire** (`http_tokens: required`) ;
   - tags `Role` et `Project` pour l'inventaire et la destruction.
7. **Attend que SSH réponde** (bannière `OpenSSH`) : « running » ne veut pas dire « SSH prêt ».
8. **Affiche un résumé** `nom -> IP publique`.

### `site.yml` — Playbook maître

Enchaîne les playbooks dans un ordre précis (par exemple, `alice` doit exister avant qu'on lui crée une crontab). Chaque étape a un tag :

| Ordre | Playbook      | Tag       | Hôtes  |
|-------|---------------|-----------|--------|
| 1     | `users.yml`   | `users`   | `prod` |
| 2     | `web.yml`     | `web`     | `web`  |
| 3     | `db.yml`      | `db`      | `db`   |
| 4     | `storage.yml` | `storage` | `db`   |
| 5     | `facts.yml`   | `facts`   | `prod` |
| 6     | `cron.yml`    | `cron`    | `web`  |

### `users.yml` — Utilisateurs, groupes et sudo

Utilisateurs définis dans `vars/users.yml` :

| Utilisateur | UID  | Fonction    | Créé sur | Groupe   |
|-------------|------|-------------|----------|----------|
| `alice`     | 3001 | developer   | `web`    | `devops` |
| `bob`       | 3002 | developer   | `web`    | `devops` |
| `carol`     | 3003 | dba         | `db`     | `dba`    |

- Groupe `devops` créé sur les serveurs web, groupe `dba` sur le serveur de base.
- Les utilisateurs sont filtrés par `when` : sur `web`, seuls les *developers* sont créés ; sur `db`, seuls les *dba*.
- Mot de passe issu du **Vault**, hashé en SHA-512 avec un **sel fixe** → même hash à chaque exécution → **idempotent**.
- Le groupe `devops` obtient `sudo` sans mot de passe via `/etc/sudoers.d/devops`, **validé par `visudo -cf`** avant dépôt (impossible de casser sudo).

### `web.yml` — Serveurs web

- Applique le rôle **`webserver`** sur le groupe `web`.
- En `post_tasks` (donc après les handlers), **teste `http://<IP publique>/health` depuis le poste de contrôle** (`delegate_to: localhost`) : le play échoue si la réponse ne contient pas `OK`.

### `db.yml` — Base de données

- Applique le rôle **`database`** sur le groupe `db` avec `become: true`.

### `storage.yml` — Stockage LVM sur `db1`

| Paramètre           | Valeur                                                                      |
|---------------------|-----------------------------------------------------------------------------|
| Disque              | `/dev/nvme1n1` (le `/dev/sdf` d'AWS vu par Linux sur une instance Nitro t3) |
| Volume group        | `vg_data`                                                                   |
| Volume logique      | `lv_backup`                                                                 |
| Système de fichiers | XFS                                                                         |
| Point de montage    | `/backup`                                                                   |

Déroulement :

1. Si le disque est **absent** des facts (`ansible_facts['devices']`), un message le signale et rien d'autre n'est fait.
2. Sinon, dans un `block` :
   - installation de `lvm2` ;
   - création du PV + VG `vg_data` ;
   - création du LV `lv_backup` en **1500 Mio**, avec **repli automatique (`rescue`) sur 800 Mio** si l'espace est insuffisant (`shrink: false` : un LV existant n'est jamais réduit) ;
   - formatage XFS (un volume déjà formaté n'est pas reformaté) ;
   - montage persistant sur `/backup` (montage immédiat + ligne dans `/etc/fstab`).

### `facts.yml` — Facts et rapports

Sur tous les serveurs (`prod`) :

1. Collecte les facts (comportement par défaut, `gather_facts`).
2. Affiche un résumé par serveur : OS, nombre de vCPU, RAM, IP privée.
3. Crée le dossier `reports/` **sur le poste de contrôle** (`delegate_to: localhost`, `run_once: true`).
4. Écrit un rapport par serveur dans `reports/<hôte>.txt` : groupes, nom système, OS, noyau, architecture, vCPU, RAM, IP privée et publique, disques.

Exemple de `reports/db1.txt` :

```
Rapport généré par Ansible
==========================
Hôte          : db1
Groupes       : aws_ec2, db, prod
Nom système   : ip-172-31-x-x
OS            : Amazon 2023
Noyau         : 6.1.x-amzn2023.x86_64
Architecture  : x86_64
vCPU          : 2
RAM totale    : 916 Mo
IP privée     : 172.31.x.x
IP publique   : x.x.x.x
Disques       : nvme0n1, nvme1n1
```

Le dossier `reports/` est exclu de Git : les rapports se régénèrent avec `ansible-playbook site.yml --tags facts`.

### `cron.yml` — Tâche planifiée

Sur les serveurs web :

1. Installe `cronie` (absent par défaut sur AL2023).
2. Démarre et active `crond`.
3. Ajoute, pour l'utilisateur `alice`, une tâche **toutes les 5 minutes** :

```
*/5 * * * * curl -s http://localhost/health >> /home/alice/health.log 2>&1
```

La ligne est identifiée par le commentaire `#Ansible: health-check`, ce qui évite les doublons.

### `adhoc.sh` — Commandes ad hoc

```bash
# git et tree sur tous les hôtes
ansible all -b -m ansible.builtin.dnf -a "name=git,tree state=present"
# Message d'accueil /etc/motd sur tous les hôtes
ansible all -b -m ansible.builtin.copy -a '{"content": "Ce serveur est gere par Ansible\n", "dest": "/etc/motd", ...}'
# Répertoire /opt/exam sur les serveurs web uniquement
ansible web -b -m ansible.builtin.file -a "path=/opt/exam state=directory owner=ec2-user group=ec2-user mode=0755"
```

---

## Les rôles

### Rôle `webserver`

| Fichier                    | Contenu                                                                   |
|----------------------------|---------------------------------------------------------------------------|
| `tasks/main.yml`           | Installe Nginx, publie la page d'accueil, ajoute `/health`, démarre Nginx |
| `templates/index.html.j2`  | Page HTML avec le nom de l'hôte et l'environnement                        |
| `templates/health.conf.j2` | `location = /health { return 200 "OK\n"; }` dans `/etc/nginx/default.d/`  |
| `handlers/main.yml`        | `nginx -t` **puis** `reload` (écoutent tous deux `Recharger nginx`)       |
| `defaults/main.yml`        | `web_env: production`, `web_docroot: /usr/share/nginx/html`               |

Le handler teste d'abord la configuration : si elle est invalide, le play échoue **avant** le rechargement, et Nginx continue de tourner avec l'ancienne configuration. Le `reload` ne coupe pas les connexions en cours.

### Rôle `database`

| Fichier             | Contenu                                                                                         |
|---------------------|-------------------------------------------------------------------------------------------------|
| `tasks/main.yml`    | Installe `mariadb105-server` + `python3-pip`, installe PyMySQL, démarre MariaDB, crée la base et l'utilisateur |
| `defaults/main.yml` | `db_name: examdb`, `db_user: appuser`, `db_socket: /var/lib/mysql/mysql.sock`                   |

- Connexion en `root` via le **socket Unix** : pas besoin de mot de passe root.
- L'utilisateur `appuser@localhost` reçoit `ALL` **uniquement** sur `examdb.*` (moindre privilège).
- Le mot de passe vient du Vault et la tâche est en `no_log: true` : il n'apparaît jamais dans la sortie.
- PyMySQL est installé via `pip` car il n'est pas packagé sur Amazon Linux 2023.

---

## Inventaire dynamique

Pas d'adresses IP écrites en dur : `inventory/aws_ec2.yml` interroge l'API AWS à chaque exécution.

```yaml
plugin: amazon.aws.aws_ec2
profile: isoset
regions: [eu-north-1]
filters:
  tag:Project: ansible-exam          # seulement les instances du projet
  instance-state-name: running       # seulement celles qui tournent
hostnames: [tag:Name]                # web1, web2, db1
compose:
  ansible_host: public_ip_address    # connexion SSH sur l'IP publique
keyed_groups:
  - key: tags.Role                   # groupes "web" et "db"
    prefix: ""
    separator: ""
```

Le fichier `inventory/groups` (format INI) déclare les groupes `web` et `db` vides et le groupe parent `prod:children`. Ainsi `prod` est toujours valide, même avant que l'inventaire dynamique ne remplisse `web` et `db`.

> Le nom du fichier d'inventaire dynamique **doit** se terminer par `aws_ec2.yml`, sinon le plugin l'ignore.

---

## Gestion des secrets (Ansible Vault)

Les secrets sont séparés en deux fichiers dans `group_vars/all/` :

| Fichier     | Chiffré | Contenu                                                                                         |
|-------------|---------|-------------------------------------------------------------------------------------------------|
| `vars.yml`  | Non     | `user_password: "{{ vault_user_password }}"`, `db_app_password: "{{ vault_db_app_password }}"` |
| `vault.yml` | **Oui** | `vault_user_password`, `vault_db_app_password`                                                  |

Cette convention (préfixe `vault_`) permet de voir quelles variables existent sans déchiffrer le vault.

Le mot de passe du vault est lu dans `.vault-pass` (déclaré dans `ansible.cfg`), fichier **exclu de Git**.

```bash
ansible-vault view group_vars/all/vault.yml     # Lire
ansible-vault edit group_vars/all/vault.yml     # Modifier
ansible-vault rekey group_vars/all/vault.yml    # Changer le mot de passe
```

Pour recréer le vault de zéro :

```bash
ansible-vault create group_vars/all/vault.yml
# contenu :
# vault_user_password: "MotDePasseUtilisateurs"
# vault_db_app_password: "MotDePasseAppuser"
```

---

## Vérifications

```bash
# Connectivité
ansible all -m ping

# Page d'accueil et health-check
curl http://<IP_web1>/
curl http://<IP_web1>/health                     # -> OK

# Utilisateurs et sudo
ansible web -m command -a "id alice"
ansible web -b -m command -a "cat /etc/sudoers.d/devops"

# Base de données
ansible db -b -m command -a "mysql -e 'SHOW DATABASES;'"

# Stockage LVM
ansible db -b -m command -a "lsblk"
ansible db -m command -a "df -h /backup"

# Crontab d'alice
ansible web -b -m command -a "crontab -l -u alice"

# Idempotence : un deuxième passage doit afficher changed=0
ansible-playbook site.yml
```

---

## Destruction de l'infrastructure

```bash
ansible-playbook destroy.yml
```

Comme `provision.yml`, il utilise le profil AWS `isoset` (via `module_defaults`) : on détruit bien dans le même compte que celui où l'on a créé.

Dans l'ordre :

1. **Termine les instances** portant le tag `Project: ansible-exam` (états pending, running, stopping, stopped) et attend la fin.
2. **Supprime le security group** `exam-sg` (possible seulement une fois les instances supprimées).
3. **Supprime la paire de clés** `ansible-exam` dans AWS.

Le volume EBS de `db1` est supprimé avec l'instance (`delete_on_termination: true`).

---

## Choix techniques et bonnes pratiques

| Pratique | Où | Pourquoi |
|----------|----|----------|
| Inventaire dynamique par tags | `inventory/aws_ec2.yml` | Aucune IP en dur ; s'adapte aux nouvelles instances |
| SSH limité à mon IP `/32` | `provision.yml` | Réduit la surface d'attaque |
| IMDSv2 obligatoire | `provision.yml` | Protège les métadonnées de l'instance (attaques SSRF) |
| Destruction filtrée par tag | `destroy.yml` | Impossible de supprimer des ressources hors projet |
| Secrets dans Ansible Vault + `no_log` | `group_vars/all/`, rôle `database` | Aucun mot de passe en clair dans le dépôt ni dans les logs |
| Sel fixe pour `password_hash` | `users.yml` | Idempotence (pas de `changed` à chaque passage) |
| `validate: visudo -cf %s` | `users.yml` | Empêche de déposer un fichier sudoers invalide |
| `nginx -t` avant `reload` | rôle `webserver` | Ne recharge jamais une configuration cassée |
| `block` / `rescue` | `storage.yml` | Repli automatique si l'espace disque manque |
| `shrink: false` | `storage.yml` | XFS ne se réduit pas : on protège les données |
| Moindre privilège MySQL | rôle `database` | `appuser` n'a des droits que sur `examdb` |
| `pipelining = True` | `ansible.cfg` | Moins d'allers-retours SSH, exécution plus rapide |
| FQCN partout (`ansible.builtin.*`) | tous les fichiers | Lisibilité et pas d'ambiguïté entre collections |

---

## Dépannage

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `ansible-inventory --graph` ne montre aucun hôte | Instances arrêtées, mauvais profil ou mauvaise région | `aws ec2 describe-instances --profile isoset --region eu-north-1` ; vérifier le tag `Project` |
| `Unable to locate credentials` | Profil `isoset` absent ou boto3 installé pour un autre Python | `aws configure --profile isoset` ; vérifier `python3 -c "import boto3"` avec l'interpréteur d'Ansible |
| `UNREACHABLE` / timeout SSH | Votre IP publique a changé depuis `provision.yml` | Relancer `ansible-playbook provision.yml` pour mettre à jour le security group |
| `Permission denied (publickey)` | Mauvaise clé privée ou droits trop ouverts | `chmod 600 ~/.ssh/isoset-lab.pem` ; vérifier `private_key_file` dans `ansible.cfg` |
| `Attempting to decrypt but no vault secrets found` | Fichier `.vault-pass` absent | Le créer (voir [Installation](#installation)) |
| `Disque de donnees absent sur db1` | Nom du disque différent (instance Xen t2 → `/dev/xvdf`) | Adapter `data_disk` dans `storage.yml` |
| `t2.micro` refusé | `t2` n'existe pas en `eu-north-1` | Garder `t3.micro` (`vars/aws.yml`) |

---

## Auteur

**Mohamed Aziz Sebihi** — Ansible Lab, ISOSET.
