#!/bin/bash

set -euo pipefail
umask 0077

show_usage () {
  cat << EOF
Usage: $(basename "$0") [OPTION]...
    -k <mandatory, Kubernetes version>          Kubernetes version, e.g. v1.18.3, to check out the Kubernetes code for building
    -b <mandatory, base image>                  the base image that node image will be built upon, e.g. kindest/base:v20200614-bb24beca
    -i <mandatory, built node image with tag>   the newly built node image with tag, e.g. kindest/node:v1.18.3
    -t <optional, build tool>                   the build tool to be used: bazel, docker. Now supports only docker
    -d <optional, image build folder>           the folder to assemble the build artifacts. Once specified, the script will leave it undeleted
    -h                                          display this help and exit
Examples:
    ./$(basename "$0") -k v1.18.3 -b kindest/base:v20200614-bb24beca -i kindest/node:v1.18.3
    ./$(basename "$0") -k v1.18.3 -b kindest/base:v20200614-bb24beca -i kindest/node:v1.18.3 -d ./_build_node_image
EOF
}

clean_up () {
    ARG=$?
    if [[ "$need_cleanup" == "true" ]]; then
        symbol=${SYMBOL_TICK}
        [[ "${ARG}" != "0" ]] && symbol=${SYMBOL_FAIL}
        echo -e -n "${symbol} Cleaning up ... "
        if [[ "${specified_folder}" == "false" ]]; then
            # clean up the folder
            rm -rf "${build_node_image_folder}" >/dev/null 2>&1 || true
        fi
        if [[ "${ARG}" == "0" ]]; then
            # clean up build container
            docker rm -f "${build_container_id}" >/dev/null 2>&1 || true
            echo "DONE!"
        else
            echo -e " As error occured, keep the container: ${build_container_id}"
        fi
    fi
    exit ${ARG}
} 
trap clean_up EXIT

# check whether a string is in the array
function array_contains () {
    local seeking=$1; shift
    local result="false"
    for element; do
        if [[ $element == "$seeking" ]]; then
            result="true"
            break
        fi
    done
    echo $result
}

# constants
# Colors
COLOR_OFF='\033[0m'
COLOR_GREEN='\x1B[0;32m'
# Symbols
SYMBOL_TICK=' \x1b[32m✓\x1b[0m'
SYMBOL_PACK='\xF0\x9F\x8E\x81'
SYMBOL_DELI='\xF0\x9F\x9A\x9A'
SYMBOL_BEER='\xF0\x9F\x8D\xBB'
SYMBOL_FAIL='\xE2\x9B\x94'

# Process command line options
kubernetes_version=""
base_image=""
node_image=""
build_tool=""
build_folder=""

need_cleanup="false"

while getopts "k:b:i:d:t:h" opt; do
    case $opt in
        k)  kubernetes_version=$OPTARG
            ;;
        b)  base_image=$OPTARG
            ;;
        i)  node_image=$OPTARG
            ;;
        d)  build_folder=$OPTARG
            ;;
        t)  
            build_tool="docker" # now docker only, ignoring the input
            ;;
        h)
            show_usage
            exit 0
            ;;
        ?)
            show_usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$kubernetes_version" ] || [ -z "$base_image" ] || [ -z "$node_image" ]; then
    echo "missing mandatory parameters..."
    show_usage >&2
    exit 1
fi

#########################
build_container_id="kind-build-$(date +"%Y%m%d-%H%M%S")"
build_node_image_folder=""
specified_folder="false"
if [ -z "${build_folder}" ]; then
    # Note: in Mac, we need extra step to support temp folder in Resources -> File Sharing
    #build_node_image_folder=$(mktemp -d)
    build_node_image_folder="_${build_container_id}"
else
    build_node_image_folder="${build_folder}"
    specified_folder="true"
    mkdir -p "${build_node_image_folder}"
fi
need_cleanup="true"

# internal variables
k8s_output_folder="${build_node_image_folder}/kubernetes/_output"
k8s_output_bin_folder="${k8s_output_folder}/dockerized/bin/linux/amd64"
k8s_output_image_folder="${k8s_output_folder}/release-images/amd64"
kind_node_image_build_folder="${build_node_image_folder}/kind"
built_images=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "kube-proxy")
extra_required_images=("kindest/kindnetd:0.5.4" "rancher/local-path-provisioner:v0.0.12" "k8s.gcr.io/debian-base:v2.0.0")
#########################

# Getting started
echo -e "${SYMBOL_TICK} Started building node image ..."
mkdir -p "${kind_node_image_build_folder}/bin"
mkdir -p "${kind_node_image_build_folder}/images"
mkdir -p "${kind_node_image_build_folder}/systemd"
mkdir -p "${kind_node_image_build_folder}/manifests"

# Checkout Kubernetes and build it
echo -e "${SYMBOL_TICK} Checking out ${COLOR_GREEN}Kubernetes ${kubernetes_version}${COLOR_OFF} ${SYMBOL_DELI}..."
rm -rf "${build_node_image_folder}/kubernetes" || true
git clone --single-branch --branch "${kubernetes_version}" --quiet \
    https://github.com/kubernetes/kubernetes.git "${build_node_image_folder}/kubernetes" >/dev/null

# Building Kubernetes
echo -e "${SYMBOL_TICK} Building ${COLOR_GREEN}Kubernetes ${kubernetes_version}${COLOR_OFF}, be patient please ..."
# Env variables
export KUBE_VERBOSE=${KUBE_VERBOSE:-0}
export KUBE_BUILD_HYPERKUBE=${KUBE_BUILD_HYPERKUBE:-n}
export KUBE_BUILD_CONFORMANCE=${KUBE_BUILD_CONFORMANCE:-n}
export KUBE_BUILD_PLATFORMS=${KUBE_BUILD_PLATFORMS:-linux/amd64}
export GOFLAGS=${GOFLAGS:=-tags=providerless,dockerless}
# remove the _output folder
rm -rf _output || true
echo -e "+++ Building Kubernetes binaries ..."
# Build Kubernetes desired binaries in Docker container and rsync out to _output folder
( cd "${build_node_image_folder}/kubernetes" && ./build/run.sh make all WHAT="cmd/kubeadm cmd/kubectl cmd/kubelet" )
# Build Kubernetes images in Docker container and rsync out to _output folder
echo -e "+++ Building Kubernetes images ..."
( cd "${build_node_image_folder}/kubernetes" && make quick-release-images )
# Capture the version info to _output folder
( cd "${build_node_image_folder}/kubernetes" && ./hack/print-workspace-status.sh | grep gitVersion | cut -d' ' -f2 | xargs echo > _output/version )

# Preparing bits for node image
echo -e "${SYMBOL_TICK} Preparing ${COLOR_GREEN}artifacts${COLOR_OFF} for node image ..."
# copy k8s output -> /bin/
for file in "kubeadm" "kubelet" "kubectl"; do
    cp "${k8s_output_bin_folder}/${file}" "${kind_node_image_build_folder}/bin/"
done
# copy over some files
cp files/init.sh "${kind_node_image_build_folder}/"
cp "${k8s_output_folder}/version" "${kind_node_image_build_folder}/"
cp files/kind/systemd/kubelet.service "${kind_node_image_build_folder}/systemd/"
cp files/etc/systemd/system/kubelet.service.d/10-kubeadm.conf "${kind_node_image_build_folder}/systemd/"
cp files/kind/manifests/default-cni.yaml "${kind_node_image_build_folder}/manifests/"
cp files/kind/manifests/default-storage.yaml "${kind_node_image_build_folder}/manifests/"

# Building node image
echo -e "${SYMBOL_TICK} Building node image in ${COLOR_GREEN}Docker container: ${build_container_id}${COLOR_OFF}${SYMBOL_PACK} ..."
# PullIfNotPresent for the specified base_image
if ! docker inspect --type=image "$base_image" >/dev/null; then
    docker pull "$base_image"
fi
# Docker run the base image
mount_point="$kind_node_image_build_folder"
[[ ! "$kind_node_image_build_folder" == /* ]] && mount_point="$(pwd)/$kind_node_image_build_folder"
docker run -d -v "${mount_point}:/build" --entrypoint=sleep --name="${build_container_id}" "$base_image" infinity >/dev/null
# Docker exec to setup tools
docker exec "${build_container_id}" bash -c "chmod +x /build/init.sh && /build/init.sh tools"
# Preparing all required images
pause_image=""
docker exec -it "${build_container_id}" bash -c "kubeadm config images list --kubernetes-version \$(cat /build/version) > /build/images/required_images"
printf "%s\n" "${extra_required_images[@]}" >> "${kind_node_image_build_folder}/images/required_images"
while IFS= read -r image; do
    # format: k8s.gcr.io/kube-apiserver:v1.18.3
    n=$( echo "$image" | cut -d':' -f1 | cut -d'/' -f2 )
    is_in_built_images=$(array_contains "${n}" "${built_images[@]}")
    if [[ "${is_in_built_images}" == "true" ]]; then
        echo "+ copy image: ${n}.tar"
        cp "${k8s_output_image_folder}/${n}.tar" "${kind_node_image_build_folder}/images/"
    else
        echo "+ docker pull image: ${image}"
        docker pull "$image" >/dev/null
        docker save -o "${kind_node_image_build_folder}/images/${n}.tar" "$image"
        if [[ "${image}" == *"pause"* ]]; then
            echo "+ the pause image is: ${image}"
            pause_image="${image}";
        fi
    fi
done < "${kind_node_image_build_folder}/images/required_images"
# containerd config
cat files/etc/containerd/config.toml | sed "s|SandboxImage|${pause_image}|g" > "${kind_node_image_build_folder}/manifests/config.toml"
# Docker exec to setup all others
docker exec "${build_container_id}" bash -c "/build/init.sh others"
# Save the image changes to a new image
docker commit --change 'ENTRYPOINT [ "/usr/local/bin/entrypoint", "/sbin/init" ]' "${build_container_id}" "${node_image}"
echo -e "${SYMBOL_TICK} Image build completed as ${node_image} ${SYMBOL_BEER}"
