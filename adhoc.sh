#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

# 1. Paquets git et tree sur tous les hôtes (dnf = gestionnaire de paquets d'AL2023)
ansible all -b -m ansible.builtin.dnf -a "name=git,tree state=present"

#
ansible all -b -m ansible.builtin.copy \
  -a '{"content": "Ce serveur est gere par Ansible\n", "dest": "/etc/motd", "owner": "root", "group": "root", "mode": "0644"}'

# 3. Répertoire /opt/exam sur les serveurs web uniquement
ansible web -b -m ansible.builtin.file -a "path=/opt/exam state=directory owner=ec2-user group=ec2-user mode=0755"


