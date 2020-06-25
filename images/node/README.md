## images/node

The node image is built programmatically, based on the [base image](../base).
Please check out the design details [here][node-image.md].

See [`pkg/build/node/node.go`][pkg/build/node/node.go] for the golang implementation.

[pkg/build/node/node.go]: ./../../pkg/build/node/node.go
[node-image.md]: https://kind.sigs.k8s.io/docs/design/node-image

Meanwhile, there is a simplified shell implementation in [build.sh](build.sh).

Overall, there are 4 major steps:

1. Check out the desired version of Kubernetes and use upstream Kubernetes' tools to build the binaries and images;

   - The binaries: `kubeadm`, `kubelet`, `kubectl`

   - The images: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`

2. Prepare all required artifacts:

   - The binaries and images built based on previous step;

   - Extra images required by `kubeadm` to boostrap Kubernetes. This may change from time to time but for now here is the list:

     - k8s.gcr.io/pause
     - k8s.gcr.io/etcd
     - k8s.gcr.io/coredns
     - kindest/kindnetd
     - rancher/local-path-provisioner
     - k8s.gcr.io/debian-base

3. Docker run the base image to start a container and build the node image from there;

4. Docker commit to create a new image from the build container.


### Usage

```sh
$ ./build.sh -h
Usage: build.sh [OPTION]...
    -k <mandatory, Kubernetes version>          Kubernetes version, e.g. v1.18.3, to check out the Kubernetes code for building
    -b <mandatory, base image>                  the base image that node image will be built upon, e.g. kindest/base:v20200614-bb24beca
    -i <mandatory, built node image with tag>   the newly built node image with tag, e.g. kindest/node:v1.18.3
    -d <optional, image build folder>           the folder to assemble the build artifacts. Once specified, the script will leave it undeleted
    -h                                          display this help and exit
Examples:
    ./build.sh -k v1.18.3 -b kindest/base:v20200614-bb24beca -i kindest/node:v1.18.3
    ./build.sh -k v1.18.3 -b kindest/base:v20200614-bb24beca -i kindest/node:v1.18.3 -d ./_build_node_imag
```

### A Typical Flow

```sh
# cd to images/node folder

# Build base image
$ (cd ../base && make quick)

# So the base image is built
$ docker images kindest/base
REPOSITORY          TAG                  IMAGE ID            CREATED             SIZE
kindest/base        v20200625-bb24beca   70002b4845d4        2 minutes ago       289MB

# Let's build the node image
$ ./build.sh -k v1.18.3 -b kindest/base:v20200614-bb24beca -i kindest/node:v1.18.3

# Once it's built, check it out
$ docker images kindest/node
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
kindest/node        v1.18.3             70f9369bf2b6        4 minutes ago       1.35GB

# Let's spin up a mult-node kind cluster
$ echo "
kind: Cluster
apiVersion: kind.sigs.k8s.io/v1alpha3
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
" | kind create cluster --image=kindest/node:v1.18.3 --config -

# Once kind cluster is created, check out the docker ps
$ docker ps
CONTAINER ID        IMAGE                  COMMAND                  CREATED             STATUS              PORTS                       NAMES
adbe2f79e07c        kindest/node:v1.18.3   "/usr/local/bin/entr…"   2 minutes ago       Up 2 minutes        127.0.0.1:56429->6443/tcp   kind-control-plane
d3fc59f51009        kindest/node:v1.18.3   "/usr/local/bin/entr…"   2 minutes ago       Up 2 minutes                                    kind-worker
eee620185a71        kindest/node:v1.18.3   "/usr/local/bin/entr…"   2 minutes ago       Up 2 minutes                                    kind-worker2
f3fc6a578c11        kindest/node:v1.18.3   "/usr/local/bin/entr…"   2 minutes ago       Up 2 minutes                                    kind-worker3

# Test it out
$ kubectl create deployment nginx --image=nginx
deployment.apps/nginx created
$ kubectl get pods
NAME                    READY   STATUS    RESTARTS   AGE
nginx-f89759699-992sq   1/1     Running   0          25s
```

> Note:

> 1. Specifying the `-d <folder>` will host all artifacts in the specified folder which won't be cleaned up automatically, which is good for learning purposes;

> 2. The upstream Kubernetes tuning parameters will still be respected, you can export them before running the `./build.sh`, following ones are embedded with defaults:

```sh
export KUBE_VERBOSE=${KUBE_VERBOSE:-0}
export KUBE_BUILD_HYPERKUBE=${KUBE_BUILD_HYPERKUBE:-n}
export KUBE_BUILD_CONFORMANCE=${KUBE_BUILD_CONFORMANCE:-n}
export KUBE_BUILD_PLATFORMS=${KUBE_BUILD_PLATFORMS:-linux/amd64}
export GOFLAGS=${GOFLAGS:=-tags=providerless,dockerless}
```
