#!/usr/bin/env bash
set -euo pipefail

function usage {
  echo -e "$1\n"
  echo "This script creates a single control-plane / multiple workers K8s cluster using *kubeadm*"
  echo "usage: k8s.sh [options]"
  echo "-v VERSION: Kubernetes version (default is 1.25.2)"
  echo "-w WORKERS: number of worker nodes (defaults is 1)"
  echo "-c CPU: cpu used by each Multipass VM (default is 2)"
  echo "-m MEM: memory used by each Multipass VM (default is 2G)"
  echo "-d DISK: disk size (default 10G)"
  echo "-p CNI: Network plugin among weavenet, calico and cilium (default)"
  echo "-D: destroy the cluster"
  echo
  echo "You can get the list of available versions with the following command:"
  echo "curl -s https://packages.cloud.google.com/apt/dists/kubernetes-xenial/main/binary-amd64/Packages | grep 'kubectl' -A2 | grep Version"
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

# Install dependencies on each node
function install_dependencies {
  # On control-plane
  echo "-> about to install dependencies on node [control-plane]"
  multipass exec control-plane -- /bin/bash -c "curl https://luc.run/kubeadm/master.sh | VERSION=$VERSION sh";
  echo "-> done installing dependencies on node [control-plane]"
  
  # On workers
  if [ "$WORKERS" -ge "1" ]; then
    for i in $(seq 1 "$WORKERS"); do
      NAME=worker$i
      echo "-> about to install dependencies on node [$NAME]"
      multipass exec "$NAME" -- /bin/bash -c "curl https://luc.run/kubeadm/worker.sh | VERSION=$VERSION sh";
      echo "-> done installing dependencies on node [$NAME]"
    done
  fi
  return 0
}

function init_cluster {
  echo "-> initializing cluster on [control-plane]"
  # Use specific Pod CIDR if Calico CNI is used
  if [ "$CNI" == "calico" ]; then
    multipass exec control-plane -- sudo kubeadm init --v=5 --pod-network-cidr=10.100.0.0/16 --ignore-preflight-errors=NumCPU,Mem || usage "Error during cluster init"
  else
    multipass exec control-plane -- sudo kubeadm init --v=5 --ignore-preflight-errors=NumCPU,Mem || usage "Error during cluster init"
  fi
  echo $'\u2714' "cluster initialized"
}

function get_kubeconfig {
  echo "-> get kubeconfig"
  # Internal for ubuntu user
  multipass exec control-plane -- /bin/bash -c "
    mkdir -p \$HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
    sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
  "
  # External on host
  multipass exec control-plane -- sudo cat /etc/kubernetes/admin.conf > kubeconfig.cfg || usage "Error retreiving kubeconfig"
}

# Add worker nodes
function add_nodes {
  JOIN=$(multipass exec control-plane -- /bin/bash -c "sudo kubeadm token create --print-join-command 2>/dev/null")
  JOIN=$(echo "sudo $JOIN" | tr -d '\r')

  if [ "$WORKERS" -ge "1" ]; then
    for i in $(seq 1 "$WORKERS"); do
      echo "-> adding worker$i"
      multipass exec worker"$i" -- /bin/bash -c "sudo $JOIN" || usage "Error while joining worker node [worker$i]"
    done
  else
    echo "-> no worker will be added"
  fi
}

function install_network_plugin {
  echo "-> installing $CNI network plugin"
  if [ "$CNI" == "weavenet" ]; then

multipass exec control-plane -- /bin/bash <<EOF
    kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s-1.11.yaml
EOF

  elif [ "$CNI" == "calico" ]; then

multipass exec control-plane -- /bin/bash <<'EOF'
  kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
  sleep 5
  curl -sSL -O https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/custom-resources.yaml
  yq e '. | select(.kind == "Installation") as $installation | select(.kind != "Installation") as $other | $installation.spec.calicoNetwork.ipPools[0].cidr = "10.100.0.0/16" | ($installation, $other)' -i custom-resources.yaml
  kubectl create -f custom-resources.yaml
EOF

  elif [ "$CNI" == "cilium" ]; then

multipass exec control-plane -- /bin/bash <<'EOF'
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')"
  curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-$OS-$ARCH.tar.gz{,.sha256sum}
  sudo tar xzvfC cilium-$OS-$ARCH.tar.gz /usr/local/bin
  rm cilium-$OS-$ARCH.tar.gz{,.sha256sum} 
  cilium install
EOF

  fi
}

function remove_taint {
  echo "-> Remove taint from the control-plane node"
  multipass exec control-plane -- kubectl taint nodes control-plane node-role.kubernetes.io/control-plane-
}

function next {
  echo "Cluster is up and ready !"
  echo "Please follow the next steps:"
  echo
  echo "- Configure your local kubectl:"
  echo "export KUBECONFIG=\$PWD/kubeconfig.cfg"
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
  rm kubeconfig.cfg 2>/dev/null
}

# Use default values if not provided
NAME="k8s"
WORKERS=1
CPU=2
MEM="2G"
DISK="10G"
VERSION="1.25.2"
CNI="cilium"

# Manage arguments
while getopts "w:c:m:d:v:p:hD" opt; do
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
    p)
      CNI=$OPTARG
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
  install_dependencies
  init_cluster
  get_kubeconfig
  remove_taint
  install_network_plugin
  add_nodes
  next
}
