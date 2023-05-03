#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "./sno-setup.sh <release image> [pull secret path]"
    echo "Usage example:"
    echo "$ ./sno-setup.sh quay.io/openshift-release-dev/ocp-release:4.12.15-x86_64 # This works if REGISTRY_AUTH_FILE is already set"
    echo "$ ./sno-setup.sh quay.io/openshift-release-dev/ocp-release:4.12.15-x86_64 ~/config/my-pull-secret"

    exit 1
fi

releaseImage=$1
pullSecretFile=${REGISTRY_AUTH_FILE}
if [ $# -eq 2 ]; then
  pullSecretFile=$2
fi

hostname=agent-sno
rendezvousIP=192.168.122.80
rendezvousMAC=52:54:07:00:00:01

### 1. Get the oc binary
if ! command -v oc &> /dev/null; then
    echo "* Installing oc binary"
    curl https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz | sudo tar -U -C /usr/local/bin -xzf -
fi

### 2. Create a temporary working folder
assets_dir=$(mktemp -d -t "agent-XXX")
cd $assets_dir
echo "* Working dir set to ${assets_dir}"

### 3. Get the openshift-installer
echo "* Extracting openshift-install from ${releaseImage}"
oc adm release extract --registry-config ${pullSecretFile} --command=openshift-install --to=${assets_dir} ${releaseImage}

### 4. Configure network, add a static mac and ip for the sno node
if ! $(sudo virsh net-dumpxml default | grep ${hostname} &> /dev/null); then
  echo "* Applying network configuration"
  sudo virsh net-update default add ip-dhcp-host "<host mac='${rendezvousMAC}' name='${hostname}' ip='${rendezvousIP}' />" --live --config
fi

### 5. Generate the install-config.yaml and agent-config.yaml 
echo "* Creating install config files"
cat > ${assets_dir}/agent-config.yaml << EOF
apiVersion: v1alpha1
metadata:
  name: ostest 
  namespace: ocp
rendezvousIP: ${rendezvousIP}
EOF

sshKey=$(echo $(cat ~/.ssh/id_rsa.pub))
pullSecret=$(echo $(cat $pullSecretFile)) 

cat > ${assets_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: test.metalkube.org
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    platform: {}
    replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {} 
  replicas: 1
metadata:
  namespace: ocp
  name: ostest
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.122.0/23
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
    none: {}
pullSecret: '${pullSecret}'
sshKey: ${sshKey}
EOF

### 6. Build the agent ISO
echo "* Creating agent ISO"
./openshift-install agent create image --dir=${assets_dir}

### 7. Start the agent virtual machine 
if $(sudo virsh list --all | grep ${hostname} &> /dev/null); then
  echo "* Removing previous ${hostname} instance"
  sudo virsh destroy ${hostname}
  sudo virsh undefine ${hostname}
fi

echo "* Launching agent SNO virtual machine"
sudo chmod a+x ${assets_dir}
sudo virt-install --connect 'qemu:///system' -n ${hostname} --vcpus 8 --memory 32678 --cdrom ${assets_dir}/agent.x86_64.iso --disk pool=default,size=100 --boot hd,cdrom --os-variant=fedora36 --network network=default,mac=${rendezvousMAC} --noautoconsole &

### 8. Wait for the installation to complete
${assets_dir}/openshift-install agent wait-for install-complete --dir=${assets_dir} --log-level=debug

