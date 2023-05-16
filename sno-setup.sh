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

network=miniagent                     # This the name of the network that will be created 
hostname=agent-sno                    # The hostname of the SNO instance
rendezvousIP=192.168.133.10           # In case of SNO, this is also the host IP
rendezvousMAC=52:54:00:93:72:25       # In case of SNO, this is also the host MAC

### 1. Get the oc binary. 
###    This will not only be used to extract the the openshift-install binary itself from the release payload,
###    but it will also be used internally by ABI
if ! command -v oc &> /dev/null; then
    echo "* Installing oc binary"
    curl https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz | sudo tar -U -C /usr/local/bin -xzf -
fi

### 2. Create a temporary working folder to store all the files required to perform the installation
assets_dir=$(mktemp -d -t "agent-XXX")
cd $assets_dir
echo "* Working dir set to ${assets_dir}"

### 3. Get the openshift-installer
echo "* Extracting openshift-install from ${releaseImage}"
oc adm release extract --registry-config ${pullSecretFile} --command=openshift-install --to=${assets_dir} ${releaseImage}

### 4. Configure network, add a static mac and ip for the sno node.
###    Some useful notes:
###    - The domain 'sno.miniagent.org' is local to the network and will not propagate upstream.
###    - The api DNS record `api.sno.miniagent.org` points directly to SNO itself
###    - SNO instance is configured with a static IP and MAC (so that they will be reused later when generating install config files)
if ! $(sudo virsh net-list | grep ${network} &> /dev/null); then
  echo "* Creating ${network} network"

  cat > ${assets_dir}/miniagent.xml << EOF
<network>
  <name>${network}</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="virbr-sno" stp="on" delay="0"/>
  <mac address="52:54:00:94:43:21"/>
  <domain name="sno.miniagent.org" localOnly="yes"/>
  <dns>
    <host ip="${rendezvousIP}">
      <hostname>master-0.sno.miniagent.org</hostname>
      <hostname>api.sno.miniagent.org</hostname>
    </host>
  </dns>
  <ip address="192.168.133.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.133.80" end="192.168.133.254"/>
      <host mac="${rendezvousMAC}" name="master-0" ip="${rendezvousIP}"/>
    </dhcp>
  </ip>
</network>
EOF

  sudo virsh net-define ${assets_dir}/miniagent.xml
  sudo virsh net-start ${network}
fi

###    The guest inside the agent network will not be resolvable from the host,
###    and this will be required later by the wait-for command
if ! $(grep "api.sno.miniagent.org" /etc/hosts &> /dev/null); then
  echo "* Adding entry to /etc/hosts"
  echo "${rendezvousIP} api.sno.miniagent.org" | sudo tee -a /etc/hosts
fi

### 5. Generate the install-config.yaml and agent-config.yaml.
###    These files will be consumed by the openshift-install later.
echo "* Creating install config files"
cat > ${assets_dir}/agent-config.yaml << EOF
apiVersion: v1alpha1
metadata:
  name: sno 
  namespace: ocp
rendezvousIP: ${rendezvousIP}
EOF

sshKey=$(echo $(cat ~/.ssh/id_rsa.pub))
pullSecret=$(echo $(cat $pullSecretFile)) 

cat > ${assets_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: miniagent.org
metadata:
  name: sno
  namespace: ocp
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {} 
  replicas: 1
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    platform: {}
    replicas: 0
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.133.0/24
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
    none: {}
pullSecret: '${pullSecret}'
sshKey: ${sshKey}
EOF

### 6. Build the agent ISO.
echo "* Creating agent ISO"
./openshift-install agent create image --dir=${assets_dir}

### 7. Start the agent virtual machine 
if $(sudo virsh list --all | grep "\s${hostname}\s" &> /dev/null); then
  echo "* Removing previous ${hostname} instance"
  sudo virsh destroy ${hostname}
  sudo virsh undefine ${hostname}
fi

echo "* Launching agent SNO virtual machine"
sudo chmod a+x ${assets_dir}
sudo virt-install \
  --connect 'qemu:///system' \
  -n ${hostname} \
  --vcpus 8 \
  --memory 32678 \
  --disk pool=default,size=100,bus=scsi \
  --disk path=${assets_dir}/agent.x86_64.iso,device=cdrom,bus=sata \
  --boot hd,cdrom\
  --network network=${network},mac=${rendezvousMAC} \
  --os-variant generic \
  --noautoconsole &

### 8. Wait for the installation to complete
${assets_dir}/openshift-install agent wait-for install-complete --dir=${assets_dir} --log-level=debug