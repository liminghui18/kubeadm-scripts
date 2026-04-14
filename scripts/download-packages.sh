#!/bin/bash
#
# Download all required packages for offline installation
# This script should be run on an internet-connected machine with the same OS architecture (ARM64)
# The downloaded packages will be used for offline installation on EulerOS servers

set -euxo pipefail

# Configuration
KUBERNETES_VERSION="v1.34"
CRICTL_VERSION="v1.35.0"
KUBERNETES_INSTALL_VERSION="1.34.0-1.1"
CALICO_VERSION="v3.31.3"

# Create directories for packages
DOWNLOAD_DIR="./offline-packages"
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR/rpm-packages"
mkdir -p "$DOWNLOAD_DIR/container-images"
mkdir -p "$DOWNLOAD_DIR/binaries"
mkdir -p "$DOWNLOAD_DIR/calico-manifests"

echo "=========================================="
echo "Downloading packages for offline installation"
echo "Target: ARM64 architecture, EulerOS"
echo "=========================================="

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) 
    CRICTL_ARCH="amd64"
    RPM_ARCH="x86_64"
    ;;
  aarch64) 
    CRICTL_ARCH="arm64"
    RPM_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Detected architecture: $ARCH ($CRICTL_ARCH)"

# Function to download with retry
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if curl -fL "$url" -o "$output"; then
            echo "Successfully downloaded: $output"
            return 0
        else
            retry=$((retry + 1))
            echo "Retry $retry/$max_retries for: $url"
            sleep 2
        fi
    done
    
    echo "Failed to download: $url"
    return 1
}

# ==========================================
# 1. Download RPM packages for EulerOS
# ==========================================
echo ""
echo "1. Downloading RPM packages..."

# Common required packages
RPM_PACKAGES=(
    "containerd"
    "curl"
    "jq"
    "socat"
    "conntrack"
    "ipset"
    "ipvsadm"
    "ebtables"
    "ethtool"
    "kmod"
    "procps-ng"
)

# Note: For EulerOS, you may need to adjust package names
# This is a template - you should download actual RPMs from EulerOS repositories
echo "RPM package list created. You need to manually download these from EulerOS repositories:"
for pkg in "${RPM_PACKAGES[@]}"; do
    echo "  - $pkg"
done

# Download containerd RPM (example for EulerOS)
echo ""
echo "Downloading containerd..."
# You would use something like:
# yumdownloader --resolve --destdir="$DOWNLOAD_DIR/rpm-packages" containerd

# ==========================================
# 2. Download Kubernetes binaries
# ==========================================
echo ""
echo "2. Downloading Kubernetes binaries..."

# Download kubeadm, kubelet, kubectl
K8S_BASE_URL="https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${CRICTL_ARCH}"

download_with_retry "$K8S_BASE_URL/kubeadm" "$DOWNLOAD_DIR/binaries/kubeadm"
download_with_retry "$K8S_BASE_URL/kubelet" "$DOWNLOAD_DIR/binaries/kubelet"
download_with_retry "$K8S_BASE_URL/kubectl" "$DOWNLOAD_DIR/binaries/kubectl"

chmod +x "$DOWNLOAD_DIR/binaries/"*

# ==========================================
# 3. Download crictl
# ==========================================
echo ""
echo "3. Downloading crictl..."

CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
download_with_retry "$CRICTL_URL" "$DOWNLOAD_DIR/binaries/crictl.tar.gz"

# ==========================================
# 4. Download Kubernetes container images
# ==========================================
echo ""
echo "4. Downloading Kubernetes container images..."

# List of Kubernetes images
K8S_IMAGES=(
    "registry.k8s.io/kube-apiserver:${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-controller-manager:${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-scheduler:${KUBERNETES_VERSION}"
    "registry.k8s.io/kube-proxy:${KUBERNETES_VERSION}"
    "registry.k8s.io/pause:3.10"
    "registry.k8s.io/etcd:3.5.21-0"
    "registry.k8s.io/coredns/coredns:v1.12.0"
)

# Pull and save images
for image in "${K8S_IMAGES[@]}"; do
    echo "Pulling image: $image"
    if docker pull "$image"; then
        # Save image to tar file
        image_name=$(echo "$image" | sed 's/[\/:]/_/g')
        docker save "$image" -o "$DOWNLOAD_DIR/container-images/${image_name}.tar"
        echo "Saved: ${image_name}.tar"
    else
        echo "Warning: Failed to pull $image"
    fi
done

# ==========================================
# 5. Download Calico manifests and images
# ==========================================
echo ""
echo "5. Downloading Calico network plugin..."

# Download Calico manifests
download_with_retry "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml" \
    "$DOWNLOAD_DIR/calico-manifests/operator-crds.yaml"

download_with_retry "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
    "$DOWNLOAD_DIR/calico-manifests/tigera-operator.yaml"

download_with_retry "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
    "$DOWNLOAD_DIR/calico-manifests/custom-resources.yaml"

# Download Calico images
CALICO_IMAGES=(
    "docker.io/calico/operator:v1.1.0"
    "docker.io/calico/apiserver:v3.31.3"
    "docker.io/calico/cni:v3.31.3"
    "docker.io/calico/csi:v3.31.3"
    "docker.io/calico/kube-controllers:v3.31.3"
    "docker.io/calico/node-driver-registrar:v3.31.3"
    "docker.io/calico/node:v3.31.3"
    "docker.io/calico/pod2daemon-flexvol:v3.31.3"
    "docker.io/calico/typha:v3.31.3"
)

for image in "${CALICO_IMAGES[@]}"; do
    echo "Pulling Calico image: $image"
    if docker pull "$image"; then
        image_name=$(echo "$image" | sed 's/[\/:]/_/g')
        docker save "$image" -o "$DOWNLOAD_DIR/container-images/${image_name}.tar"
        echo "Saved: ${image_name}.tar"
    else
        echo "Warning: Failed to pull $image"
    fi
done

# ==========================================
# 6. Create package list file
# ==========================================
echo ""
echo "6. Creating package list..."

cat > "$DOWNLOAD_DIR/package-list.txt" << EOF
Offline Kubernetes Installation Package List
============================================
Architecture: $ARCH ($CRICTL_ARCH)
Kubernetes Version: $KUBERNETES_VERSION
Calico Version: $CALICO_VERSION

Binaries:
- kubeadm
- kubelet
- kubectl
- crictl

Container Images:
$(ls -1 "$DOWNLOAD_DIR/container-images" | sed 's/^/- /')

Calico Manifests:
- operator-crds.yaml
- tigera-operator.yaml
- custom-resources.yaml

Required RPM Packages (download from EulerOS repos):
$(for pkg in "${RPM_PACKAGES[@]}"; do echo "- $pkg"; done)
EOF

# ==========================================
# 7. Create checksums
# ==========================================
echo ""
echo "7. Creating checksums..."

cd "$DOWNLOAD_DIR"
find . -type f -exec sha256sum {} \; > checksums.txt
cd -

echo ""
echo "=========================================="
echo "Download complete!"
echo "=========================================="
echo "Packages saved to: $DOWNLOAD_DIR"
echo ""
echo "Next steps:"
echo "1. Copy the entire '$DOWNLOAD_DIR' directory to your offline servers"
echo "2. Run the offline installation scripts"
echo "=========================================="
