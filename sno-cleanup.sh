#!/bin/bash
set -euo pipefail

source "sno-common.sh"

# Remove any existing mini-agent instance
if sudo virsh list --all --name | grep -q "${hostname}"; then
  echo "* Removing ${hostname} instance"
  if sudo virsh list --name | grep -q "${hostname}"; then
      sudo virsh destroy ${hostname}
  fi
  sudo virsh undefine ${hostname} --remove-all-storage
fi

# Remove any existing worker
if sudo virsh list --all --name | grep -q "${workerName}"; then
  echo "* Removing ${workerName} instance"
  if sudo virsh list --name | grep -q "${workerName}"; then
      sudo virsh destroy ${workerName}
  fi
  sudo virsh undefine ${workerName} --remove-all-storage
fi

# Remove the mini-agent network
if sudo virsh net-list --all --name | grep -q ${network}; then
  echo "* Removing ${network} network"
  if sudo virsh net-list --name | grep -q ${network}; then
      sudo virsh net-destroy ${network}
  fi
  sudo virsh net-undefine ${network}
fi 

# Cleanup the /etc/hosts file
sudo sed -i "/${baseDomain}/d" /etc/hosts

# Remove the temporary working dir
if [[ -d "${assets_dir}" && ${assets_dir} == *"mini-agent" ]]; then
    echo "* Removing ${assets_dir} folder"
    rm -rf ${assets_dir}
fi
