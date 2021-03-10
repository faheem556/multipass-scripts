#!/bin/bash -x

source $(dirname 0)/env.sh

multipass delete $K3S_SERVER > /dev/null 2>&1
multipass delete $K3S_AGENT1 > /dev/null 2>&1
multipass delete $K3S_AGENT2 > /dev/null 2>&1
multipass delete $K3S_AGENT3  > /dev/null 2>&1
multipass purge