#!/bin/bash
set -euo pipefail

source "sno-common.sh"

# Remove any existing mini-agent instance
if $(sudo virsh list --all | grep "\s${hostname}\s" &> /dev/null); then
  echo "* Removing ${hostname} instance"
  sudo virsh destroy ${hostname}
  sudo virsh undefine ${hostname}
fi

# Remove the mini-agent network
if $(sudo virsh net-list | grep ${network} &> /dev/null); then
    echo "* Removing ${network} network"
    sudo virsh net-destroy ${network}
    sudo virsh net-undefine ${network}
fi 

# Cleanup the /etc/hosts file
sudo sed -i "/${baseDomain}/d" /etc/hosts

# Remove the temporary working dir
if [[ -d "${assets_dir}" && ${assets_dir} == *"mini-agent" ]]; then
    echo "* Removing ${assets_dir} folder"
    rm -rf ${assets_dir}
fi
