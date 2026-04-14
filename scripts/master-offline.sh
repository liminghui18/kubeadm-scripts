#!/bin/bash
#
# Setup for Control Plane (Master) servers - OFFLINE VERSION
# This script initializes Kubernetes master from local packages
# Target: ARM CPU, EulerOS

set -euxo pipefail

# Offline package directory (adjust this path as needed)
OFFLINE_PKG_DIR="${OFFLINE_PKG_DIR:-./offline-packages}"

# Check if offline package directory exists
if [ ! -d "$OFFLINE_PKG_DIR" ]; then
    echo "Error: Offline package directory not found: $OFFLINE_PKG_DIR"
    echo "Please set OFFLINE_PKG_DIR environment variable or copy packages to ./offline-packages"
    exit 1
fi

# If you need public access to API server using the servers Public IP address, change PUBLIC_IP_ACCESS to true.
PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)
POD_CIDR="192.168.0.0/16"

echo "=========================================="
echo "Kubernetes Master Initialization (Offline)"
echo "=========================================="

# ==========================================
# Load Kubernetes container images
# ==========================================
echo ""
echo "Loading Kubernetes container images..."

if [ -d "$OFFLINE_PKG_DIR/container-images" ]; then
    for image_tar in "$OFFLINE_PKG_DIR/container-images/"*.tar; do
        if [ -f "$image_tar" ]; then
            echo "Loading image: $image_tar"
            # Try containerd first, then docker
            sudo ctr -n k8s.io images import "$image_tar" 2>/dev/null || \
            sudo docker load -i "$image_tar" 2>/dev/null || \
            echo "Warning: Failed to load $image_tar (may already be loaded)"
        fi
    done
else
    echo "Warning: No container images directory found"
fi

# List loaded images
echo ""
echo "Loaded container images:"
sudo ctr -n k8s.io images ls 2>/dev/null || sudo docker images 2>/dev/null || echo "Could not list images"

# ==========================================
# Initialize Kubernetes cluster with kubeadm
# ==========================================
echo ""
echo "Initializing Kubernetes cluster..."

# Get master IP address
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "Error: Could not determine primary network interface"
    exit 1
fi

MASTER_PRIVATE_IP=$(ip addr show "$PRIMARY_INTERFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

if [ -z "$MASTER_PRIVATE_IP" ]; then
    echo "Error: Could not determine master IP address"
    exit 1
fi

echo "Master IP: $MASTER_PRIVATE_IP"
echo "Node name: $NODENAME"
echo "Pod CIDR: $POD_CIDR"

# Initialize kubeadm based on PUBLIC_IP_ACCESS
if [[ "$PUBLIC_IP_ACCESS" == "false" ]]; then
    echo "Initializing with private IP..."
    sudo kubeadm init \
        --apiserver-advertise-address="$MASTER_PRIVATE_IP" \
        --apiserver-cert-extra-sans="$MASTER_PRIVATE_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap \
        --image-repository registry.k8s.io

elif [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then
    echo "Error: PUBLIC_IP_ACCESS=true requires internet connection to detect public IP"
    echo "Please set PUBLIC_IP_ACCESS=false for offline installation"
    exit 1

else
    echo "Error: PUBLIC_IP_ACCESS has an invalid value: $PUBLIC_IP_ACCESS"
    exit 1
fi

# ==========================================
# Configure kubeconfig
# ==========================================
echo ""
echo "Configuring kubeconfig..."

mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

echo "Kubeconfig configured successfully"

# ==========================================
# Install Calico Network Plugin (Offline)
# ==========================================
echo ""
echo "Installing Calico network plugin..."

CALICO_MANIFESTS_DIR="$OFFLINE_PKG_DIR/calico-manifests"

if [ -d "$CALICO_MANIFESTS_DIR" ]; then
    # Install Tigera Operator and CRDs
    echo "Applying Calico operator CRDs..."
    kubectl create -f "$CALICO_MANIFESTS_DIR/operator-crds.yaml" || echo "CRDs may already exist"
    
    echo "Applying Tigera operator..."
    kubectl create -f "$CALICO_MANIFESTS_DIR/tigera-operator.yaml" || echo "Operator may already exist"
    
    echo "Waiting for Calico operator to be ready..."
    sleep 120
    
    # Download custom resources
    if [ -f "$CALICO_MANIFESTS_DIR/custom-resources.yaml" ]; then
        cp "$CALICO_MANIFESTS_DIR/custom-resources.yaml" ./custom-resources.yaml
        
        # Get cluster CIDR from kube-controller-manager
        CLUSTER_CIDR=$(kubectl -n kube-system get pod -l component=kube-controller-manager -o yaml 2>/dev/null | grep -i cluster-cidr | awk '{print $2}' | sed 's/--cluster-cidr=//')
        
        if [ -z "$CLUSTER_CIDR" ]; then
            echo "Warning: Could not detect cluster CIDR, using default $POD_CIDR"
            CLUSTER_CIDR="$POD_CIDR"
        fi
        
        echo "Using cluster CIDR: $CLUSTER_CIDR"
        
        # Update CIDR in custom-resources.yaml
        sed -i "s|cidr: 192.168.0.0/16|cidr: $CLUSTER_CIDR|g" custom-resources.yaml
        
        # Apply custom resources
        echo "Applying Calico custom resources..."
        kubectl apply -f custom-resources.yaml
        
        echo "Waiting for Calico to be ready..."
        sleep 60
    else
        echo "Warning: custom-resources.yaml not found"
    fi
else
    echo "Warning: Calico manifests directory not found: $CALICO_MANIFESTS_DIR"
    echo "Network plugin will not be installed automatically"
fi

# ==========================================
# Verification
# ==========================================
echo ""
echo "=========================================="
echo "Master initialization completed!"
echo "=========================================="
echo ""
echo "Cluster information:"
kubectl cluster-info
echo ""
echo "Node status:"
kubectl get nodes -o wide
echo ""
echo "Pod status:"
kubectl get pods -A
echo ""
echo "Join command for worker nodes:"
kubeadm token create --print-join-command
echo ""
echo "=========================================="
echo "Next steps:"
echo "1. Verify all pods are running: kubectl get pods -A"
echo "2. Copy the join command above to add worker nodes"
echo "3. Run common-offline.sh on worker nodes, then join the cluster"
echo "=========================================="
