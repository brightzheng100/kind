#!/bin/bash

set -euo pipefail
umask 0077

function init_tools() {
    # rsync bin
    rsync -r /build/bin /kind/
    cp /build/version /kind/

    # install the kube bits
    for f in "kubeadm" "kubelet" "kubectl"; do
        ln -s -f /kind/bin/${f} /usr/bin/${f}
    done
}

function init_others() {
    mkdir -p /etc/systemd/system/kubelet.service.d/
    mkdir -p /etc/containerd

    # rsync all
    rsync -r /build/manifests /kind/
    rsync -r /build/systemd /kind/

    # enable the kubelet service
    systemctl enable /kind/systemd/kubelet.service
    mv /kind/systemd/10-kubeadm.conf /etc/systemd/system/kubelet.service.d/

    # ensure we don't fail if swap is enabled on the host
    echo "KUBELET_EXTRA_ARGS=--fail-swap-on=false" >> /etc/default/kubelet

    # configure & start up containerd
    mv /kind/manifests/config.toml /etc/containerd/
    nohup /usr/local/bin/containerd > /dev/null 2>&1 &

    # import all images
    for image in /build/images/*.tar; do
        file_name="$( basename $image )"
        echo "+ importing image: ${file_name}"
        ctr --namespace=k8s.io images import --all-platforms --no-unpack /build/images/${file_name}
    done

    # ls images
    echo "+ listing all imported images"
    ctr --namespace=k8s.io images ls -q

    # kill containerd
    pkill containerd
}

phase=$1

if [[ "${phase}" = "tools" ]]; then
    init_tools
elif [[ "${phase}" = "others" ]]; then
    init_others
else
    echo "no such phase"
    exit 1
fi
