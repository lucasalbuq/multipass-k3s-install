# multipass-k3s-install



### K8S

```
$ curl https://luc.run/k8s.sh | bash -s
export KUBECONFIG=$PWD/kubeconfig.cfg

```

```
$ ./k8s.sh
...
-v VERSION: Kubernetes version (default is 1.25.2)
-w WORKERS: number of worker nodes (defaults is 1)
-c CPU: cpu used by each Multipass VM (default is 2)
-m MEM: memory used by each Multipass VM (default is 2G)
-d DISK: disk size (default 10G)
-p CNI: Network plugin among weavenet, calico and cilium (default)
-D: destroy the cluster

$ curl https://luc.run/k8s.sh | bash -s -- -w 2 -p calico

```
---

### K3S

```
$ curl https://luc.run/k3s.sh | bash -s
export KUBECONFIG=$PWD/kubeconfig.k3s

```


```
$ ./k3s.sh -h
...
-w WORKERS: number of worker nodes (defaults is 1)
-c CPU: cpu used by each VM (default is 2)
-m MEMORY: memory used by each VM (default is 2G)
-d DISK: disk space used by each VM (default is 10G)
-D: destroy the cluster


$ curl https://luc.run/k3s.sh | bash -s -- -w 4

```

---

### K0S

```
$ curl https://luc.run/k0s.sh | bash -s
```
