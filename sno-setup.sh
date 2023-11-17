#!/bin/bash
set -euo pipefail

source "sno-common.sh"

### 1. Initial checks 
if [ $# -lt 1 ]; then
    echo "./sno-setup.sh <release image> [pull secret path]"
    echo "Usage example:"
    echo "$ ./sno-setup.sh quay.io/openshift-release-dev/ocp-release:4.14.3-x86_64 # This works if REGISTRY_AUTH_FILE is already set"
    echo "$ ./sno-setup.sh quay.io/openshift-release-dev/ocp-release:4.14.3-x86_64 ~/config/my-pull-secret"

    exit 1
fi

releaseImage=$1
pullSecretFile=${REGISTRY_AUTH_FILE:-}
if [ $# -eq 2 ]; then
  pullSecretFile=$2
fi

if $(sudo virsh list --all | grep "\s${hostname}\s" &> /dev/null); then
  echo "Found an already existing mini-agent instance, please run sno-cleanup.sh to remove it"
  exit 1
fi

start=$(date +%s)

### 2. Create a temporary working folder and make it accessible to the qemu and current user
mkdir -p ${assets_dir}

### 3. Get the oc binary. 
###    This will not only be used to extract the the openshift-install binary itself from the release payload,
###    but it will also be used internally by ABI
if ! command -v oc &> /dev/null; then
    echo "* Installing oc binary"
    curl https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz | sudo tar -U -C /usr/local/bin -xzf -
fi

### 4. Get the openshift-installer
extractOptions="--command=openshift-install --to=${assets_dir} ${releaseImage}"

pullSecret='{"auths": {"empty": {"auth": "ZW1wdHk6ZW1wdHkK"}}}' ### empty secret
if [ ! -z ${pullSecretFile} ]; then
  pullSecret=$(echo $(cat $pullSecretFile)) 
  extractOptions="--registry-config=${pullSecretFile} ${extractOptions}"
fi

echo "* Extracting openshift-install from ${releaseImage}"
oc adm release extract ${extractOptions}

### 5. Configure network, add a static mac and ip for the sno node.
###    Some useful notes:
###    - The domain is local to the network and will not propagate upstream.
###    - The api DNS record points directly to SNO itself
###    - SNO instance is configured with a static IP and MAC (so that they will be reused later when generating install config files)
if ! $(sudo virsh net-list | grep ${network} &> /dev/null); then
  echo "* Creating ${network} network"

  cat > ${assets_dir}/${network}.xml << EOF
<network>
  <name>${network}</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="virbr-sno" stp="on" delay="0"/>
  <mac address="52:54:00:94:43:21"/>
  <domain name="${domain}" localOnly="yes"/>
  <dns>
    <host ip="${rendezvousIP}">
      <hostname>master-0.${domain}</hostname>
      <hostname>${apiDomain}</hostname>
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

  sudo virsh net-define ${assets_dir}/${network}.xml
  sudo virsh net-start ${network}
fi

###    The guest inside the agent network will not be resolvable from the host,
###    and this will be required later by the wait-for command
if ! $(grep "${apiDomain}" /etc/hosts &> /dev/null); then
  echo "* Adding entry to /etc/hosts"
  echo "${rendezvousIP} ${apiDomain}" | sudo tee -a /etc/hosts
fi

### 6. Generate the install-config.yaml and agent-config.yaml.
###    These files will be consumed by the openshift-install later.
echo "* Creating install config files"
cat > ${assets_dir}/agent-config.yaml << EOF
apiVersion: v1alpha1
metadata:
  name: sno 
  namespace: mini-agent
rendezvousIP: ${rendezvousIP}
EOF

sshKey=$(echo $(cat ~/.ssh/id_rsa.pub))

cat > ${assets_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${baseDomain}
metadata:
  name: sno
  namespace: mini-agent
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

### 7. Build the agent ISO.
echo "* Creating agent ISO"
${assets_dir}/openshift-install agent create image --dir=${assets_dir} --log-level=debug

### 8. Start the agent virtual machine 
echo "* Launching agent SNO virtual machine"
sudo chmod a+x ${assets_dir}
sudo virt-install \
  --connect 'qemu:///system' \
  -n ${hostname} \
  --vcpus 8 \
  --memory 32768 \
  --disk size=100,bus=virtio,cache=none,io=native \
  --disk path=${assets_dir}/agent.x86_64.iso,device=cdrom,bus=sata \
  --boot hd,cdrom \
  --import \
  --network network=${network},mac=${rendezvousMAC} \
  --os-variant generic \
  --noautoconsole &


### 9. Check if the agent virtual machine is up and running
while ! $(sudo virsh list --all | grep "\s${hostname}\s.*running" &> /dev/null); do
  echo "Waiting for ${hostname} to start..."
  sleep 5
done

### 10. Wait for the installation to complete
${assets_dir}/openshift-install agent wait-for install-complete --dir=${assets_dir} --log-level=debug

end=$(date +%s)
echo ""
echo "Cluster deployed in $(((end - start) / 60)) minutes"
