#!/bin/bash

# This file contains just the variables shared 
# between the setup/cleanup scripts

assets_dir=/tmp/mini-agent            # Temporary folder to store all the files required to perform the installation
network=mini-agent                    # This the name of the network that will be created 
hostname=agent-sno                    # The hostname of the SNO instance
rendezvousIP=192.168.133.80           # In case of SNO, this is also the host IP
rendezvousMAC=52:54:00:93:72:25       # In case of SNO, this is also the host MAC

baseDomain=${network}.org
domain=sno.${baseDomain}
apiDomain=api.${domain}

