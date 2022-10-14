#!/usr/bin/env bash
set -euo pipefail

function usage {
  echo -e "$1\n"
  echo "This script creates a single master / multiple workers K3s cluster"
  echo "usage: k3s.sh [options]"
  echo "-w WORKERS: number of worker nodes (defaults is 1)"
  echo "-c CPU: cpu used by each VM (default is 2)"
  echo "-m MEMORY: memory used by each VM (default is 2G)"
  echo "-d DISK: disk space used by each VM (default is 10G)"
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

function create-vms {
  echo "-> creating Ubuntu VMs with Multipass"

  # Creating control-plane node
  multipass launch --name control-plane --cpus "$CPU" --mem "$MEM" --disk "$DISK" || usage "Error creating [control-plane] VM"

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
  echo "-> initializing cluster on [control-plane]"
  multipass exec control-plane -- /bin/bash -c "curl -sfL https://get.k3s.io | sh -s - --no-deploy=traefik" || usage "Error during cluster init"
  echo $'\u2714' "cluster initialized"
  return 0
}

function get-context {
  echo "-> getting cluster configuration"
  multipass exec control-plane sudo cat /etc/rancher/k3s/k3s.yaml > kubeconfig.k3s || usage "Error retreiving kubeconfig"

  # Set master's external IP in the configuration file
  IP=$(multipass info control-plane | grep IPv4 | awk '{print $2}')
  sed -i.local "s/127\.0\.0\.1/$IP/" kubeconfig.k3s
}

function add-nodes {
  # Get control-plane's IP and TOKEN used to join nodes
  IP=$(multipass info control-plane | grep IPv4 | awk '{print $2}')
  URL="https://$IP:6443"
  TOKEN=$(multipass exec control-plane sudo cat /var/lib/rancher/k3s/server/node-token)

  # Join worker nodes
  if [ "$WORKERS" -ge "1" ]; then
    for i in $(seq 1 "$WORKERS"); do
      NAME=worker$i
      echo "-> adding [$NAME] node"
      if ! multipass exec "$NAME" -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=\"$URL\" K3S_TOKEN=\"$TOKEN\" sh -"; then
        echo "Error while joining [$NAME] node";
      else
        echo $'\u2714' "Node [$NAME] added !"
      fi
    done
  else
    echo "-> no worker will be added"
  fi
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
  rm kubeconfig.k3s kubeconfig.k3s.local 2>/dev/null
}

function next {
  # Setup needed on the local machine
  echo
  echo "Cluster is up and ready !"
  echo "Please follow the next steps:"
  echo
  echo "- Configure your local kubectl:"
  echo "export KUBECONFIG=\$PWD/kubeconfig.k3s"
  echo
  echo "- Make sure the nodes are in READY state:"
  echo "kubectl get nodes"
  echo
}

# Use default values if not provided
WORKERS=1
CPU=2
MEM="2G"
DISK="10G"

# Manage arguments
while getopts "w:c:m:d:hD" opt; do
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
    h)
      usage ""
      ;;
    *)
      usage ""
      ;;
  esac
done

# Run the setup process
{
  check-multipass
  check-kubectl
  create-vms
  init-cluster
  get-context
  add-nodes
  next
}
