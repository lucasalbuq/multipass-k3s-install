#!/usr/bin/env bash
set -euo pipefail

function usage {
  echo -e "$1\n"
  echo "This script creates a single control-plane / multiple workers k0s cluster"
  echo "usage: k0s.sh [options]"
  echo "-v VERSION: Kubernetes version (default is v1.25.2+k0s.0)"
  echo "-w WORKERS: number of worker nodes (defaults is 2)"
  echo "-c CPU: cpu used by each Multipass VM (default is 2)"
  echo "-m MEM: memory used by each Multipass VM (default is 2G)"
  echo "-d DISK: disk size (default 10G)"
  echo "-D: destroy the cluster"
  echo
  echo "Prerequisites:"
  echo "- Multipass (https://multipass.run) must be installed"
  echo "- kubectl must be installed"
  exit 0
}

function check-multipass {
  echo "-> making sure Multipass is installed"
  multipass version 1>/dev/null 2>&1 || usage "Please install Multipass (https://multipass.run)"
}

function check-kubectl {
  echo "-> making sure kubectl is installed"
  kubectl 1>/dev/null 2>&1 || usage "Please install kubectl"
}

# Create the control-plane and workers VM using Multipass
function create-vms {
  echo "-> creating Ubuntu VMs with Multipass"

  # Creating control-plane node
  multipass launch --name control-plane --mem "$MEM" --cpus "$CPU" --disk "$DISK" || usage "Error creating [control-plane] VM"

  # Creating worker nodes
  if [ "$WORKERS" -ge "1" ]; then
    for i in $(seq 1 "$WORKERS"); do
      NAME=worker$i
      multipass launch --name "$NAME" --cpus "$CPU" --mem "$MEM" --disk "$DISK" || usage "Error creating [$NAME] VM"
    done
  else
    echo "-> no worker VM requested"
  fi
  echo $'\u2714' "VMs created"
}

function init-cluster {
  multipass exec control-plane -- /bin/bash -c "
    curl -sSLf https://get.k0s.sh | sudo K0S_VERSION=$VERSION sh
    sudo mkdir -p /etc/k0s
    k0s config create | sudo tee /etc/k0s/k0s.yaml >/dev/null
    sudo k0s install controller -c /etc/k0s/k0s.yaml
    sudo k0s start
    while [ ! -f /var/lib/k0s/pki/admin.conf ]; do sleep 1;done
  "
}

function get-context {
  echo "-> get cluster configuration"
  # Internal for ubuntu user
  multipass exec control-plane -- /bin/bash -c "
    mkdir /home/ubuntu/.kube
    sudo cp /var/lib/k0s/pki/admin.conf /home/ubuntu/.kube/config
    sudo chown -R ubuntu:ubuntu  /home/ubuntu/.kube/ /var/lib/k0s/pki/admin.conf
  "

  # External on host
  multipass exec control-plane -- sudo cat /var/lib/k0s/pki/admin.conf > kubeconfig.k0s || usage "Error retreiving kubeconfig"
  IP=$(multipass info control-plane | grep IP | awk '{print $2}')
  sed -i.local "s/localhost/$IP/" kubeconfig.k0s
}

# Add worker nodes
function add-nodes {
  multipass exec control-plane -- /bin/bash -c "sudo k0s token create --role=worker 2>/dev/null" > token.k0s

  if [ "$WORKERS" -ge "1" ]; then
    for i in $(seq 1 "$WORKERS"); do
      echo "-> adding worker$i"
      # Copy token to worker
      multipass transfer token.k0s "worker$i":/home/ubuntu/token.k0s

      # Init worker
      multipass exec worker"$i" -- /bin/bash -c "
        curl -sSLf https://get.k0s.sh | sudo K0S_VERSION=$VERSION sh
        sudo k0s install worker --token-file /home/ubuntu/token.k0s
        sudo k0s start
      "
    done
  else
    echo "-> no worker will be added"
  fi
}

function next {
  echo "Cluster is up and ready !"
  echo "Please follow the next steps:"
  echo
  echo "- Configure your local kubectl:"
  echo "export KUBECONFIG=\$PWD/kubeconfig.k0s"
  echo
  echo "- Check the nodes getting ready (might take around 1 minute):"
  echo "kubectl get nodes"
  echo
}

function destroy {
  echo "About to destroy the cluster..."
  if ! multipass info control-plane &>/dev/null; then
    echo "Seems there is no control-plane node here... aborting"
    exit 1
  else
    echo "-> deleting control-plane node"
    multipass delete -p control-plane
  fi
  for worker in $(multipass list | grep worker | awk '{print $1}'); do
    echo "-> deleting $worker"
    multipass delete -p "$worker"
  done
  # Delete kubeconfig file
  rm kubeconfig.k0s kubeconfig.k0s.local 2>/dev/null
  rm token.k0s
}

# Use default values if not provided
WORKERS=2
CPU=2
MEM="2G"
DISK="10G"
VERSION="v1.25.2+k0s.0"

# Manage arguments
while getopts "w:c:m:d:v:hD" opt; do
  case $opt in
    D)
      destroy
      exit
      ;;
    w)
      WORKERS=$OPTARG
      ;;
    c)
      CPU=$OPTARG
      ;;
    m)
      MEM=$OPTARG
      ;;
    d)
      DISK=$OPTARG
      ;;
    v)
      VERSION=$OPTARG
      ;;
    h)
      usage ""
      ;;
    *)
      usage ""
      ;;
  esac
done

# Run setup process
{
  check-multipass
  check-kubectl
  create-vms
  init-cluster
  get-context
  add-nodes
  next
}
