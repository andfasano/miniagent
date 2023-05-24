# Miniagent

This repo contains a number of utility scripts to setup a virtualized cluster using agent-based installer (ABI).
The main goal is to provid a quick and easy playground so that any user could be able to try out and experiment
the various features of ABI, by using the simplest approach possible.

These scripts were synthesized thanks to the experience and contributions of the various authors of [dev-scripts](https://github.com/openshift-metal3/dev-scripts/)

# Limitations

The current scripts are limited to the SNO topology

# Pre-requisites

* Requires [libvirt](https://libvirt.org/compiling.html)
    * [virt-manager](https://virt-manager.org/) is recommended
* A valid pull secret
* An ssh key stored in `~/.ssh/id_rsa.pub`

# Getting started

1. Launch the setup script specifying the required release version and the the pull secret file.

```
$ ./sno-setup.sh quay.io/openshift-release-dev/ocp-release:4.13.0-x86_64 ~/config/my-pull-secret
```

> **_NOTE:_**  The pull secret file parameter is not required if the `REGISTRY_AUTH_FILE` environment variable is already set

2. Wait for the installation to complete. The console will show a detailed output about each phase of the installation.

```
...
INFO Cluster is installed                         
INFO Install complete!                            
INFO To access the cluster as the system:admin user when using 'oc', run 
INFO     export KUBECONFIG=/tmp/agent-DvM/auth/kubeconfig 
...
```

> **_NOTE:_**  The static IP of the node is `192.168.133.10`

3. Connect to your new cluster using the credentials stored in the asset folder.

```
$ export KUBECONFIG=/tmp/agent-DvM/auth/kubeconfig
$ oc get nodes
NAME       STATUS   ROLES                         AGE   VERSION
master-0   Ready    control-plane,master,worker   36m   v1.26.3+b404935
```
