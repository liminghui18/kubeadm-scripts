#!/bin/bash
#
# Common setup for all servers (Control Plane and Nodes) - OFFLINE VERSION
# This script installs Kubernetes from local packages without internet access
# Target: ARM CPU, EulerOS

set -euxo pipefail

# Kubernetes Variable Declaration
KUBERNETES_VERSION="v1.34"
CRICTL_VERSION="v1.35.0"
KUBERNETES_INSTALL_VERSION="1.34.0-1.1"

# Offline package directory (adjust this path as needed)
OFFLINE_PKG_DIR="${OFFLINE_PKG_DIR:-./offline-packages}"

# Check if offline package directory exists
if [ ! -d "$OFFLINE_PKG_DIR" ]; then
    echo "Error: Offline package directory not found: $OFFLINE_PKG_DIR"
    echo "Please set OFFLINE_PKG_DIR environment variable or copy packages to ./offline-packages"
    exit 1
fi

echo "=========================================="
echo "Offline Kubernetes Installation"
echo "Package directory: $OFFLINE_PKG_DIR"
echo "=========================================="

# Disable swap
sudo swapoff -a

# Keeps the swap off during reboot
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

# Create the .conf file to load the modules at bootup
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# ==========================================
# Install RPM packages from local directory
# ==========================================
echo ""
echo "Installing RPM packages from local directory..."

if [ -d "$OFFLINE_PKG_DIR/rpm-packages" ]; then
    # Install all RPM packages in the directory
    sudo rpm -Uvh "$OFFLINE_PKG_DIR/rpm-packages/"*.rpm --nodeps || true
    
    # Or use yum localinstall if available
    if command -v yum &> /dev/null; then
        sudo yum localinstall -y "$OFFLINE_PKG_DIR/rpm-packages/"*.rpm || true
    fi
else
    echo "Warning: No RPM packages directory found"
fi

# ==========================================
# Install containerd (if not already installed via RPM)
# ==========================================
echo ""
echo "Configuring containerd..."

# Check if containerd is installed
if ! command -v containerd &> /dev/null; then
    echo "Error: containerd is not installed"
    echo "Please ensure containerd RPM is in $OFFLINE_PKG_DIR/rpm-packages/"
    exit 1
fi

sudo systemctl daemon-reload
sudo systemctl enable containerd --now
sudo systemctl start containerd.service

echo "Containerd runtime installed successfully"

# Generate the default containerd configuration
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd to apply changes
sudo systemctl restart containerd

# ==========================================
# Install crictl from local binary
# ==========================================
echo ""
echo "Installing crictl..."

if [ -f "$OFFLINE_PKG_DIR/binaries/crictl.tar.gz" ]; then
    sudo tar zxvf "$OFFLINE_PKG_DIR/binaries/crictl.tar.gz" -C /usr/local/bin
elif [ -f "$OFFLINE_PKG_DIR/binaries/crictl" ]; then
    sudo install -m 0755 "$OFFLINE_PKG_DIR/binaries/crictl" /usr/local/bin/crictl
else
    echo "Error: crictl binary not found in $OFFLINE_PKG_DIR/binaries/"
    exit 1
fi

# Configure crictl to use containerd
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "crictl installed and configured successfully"

# ==========================================
# Install Kubernetes binaries (kubeadm, kubelet, kubectl)
# ==========================================
echo ""
echo "Installing Kubernetes binaries..."

# Install from local binaries
if [ -f "$OFFLINE_PKG_DIR/binaries/kubeadm" ]; then
    sudo install -m 0755 "$OFFLINE_PKG_DIR/binaries/kubeadm" /usr/bin/kubeadm
else
    echo "Error: kubeadm binary not found"
    exit 1
fi

if [ -f "$OFFLINE_PKG_DIR/binaries/kubelet" ]; then
    sudo install -m 0755 "$OFFLINE_PKG_DIR/binaries/kubelet" /usr/bin/kubelet
else
    echo "Error: kubelet binary not found"
    exit 1
fi

if [ -f "$OFFLINE_PKG_DIR/binaries/kubectl" ]; then
    sudo install -m 0755 "$OFFLINE_PKG_DIR/binaries/kubectl" /usr/bin/kubectl
else
    echo "Error: kubectl binary not found"
    exit 1
fi

# Create kubelet systemd service
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create kubelet drop-in directory
sudo mkdir -p /etc/systemd/system/kubelet.service.d

# Enable kubelet
sudo systemctl daemon-reload
sudo systemctl enable kubelet

echo "Kubernetes binaries installed successfully"

# ==========================================
# Load container images
# ==========================================
echo ""
echo "Loading container images..."

if [ -d "$OFFLINE_PKG_DIR/container-images" ]; then
    for image_tar in "$OFFLINE_PKG_DIR/container-images/"*.tar; do
        if [ -f "$image_tar" ]; then
            echo "Loading image: $image_tar"
            sudo ctr -n k8s.io images import "$image_tar" || \
            sudo docker load -i "$image_tar" || \
            echo "Warning: Failed to load $image_tar"
        fi
    done
else
    echo "Warning: No container images directory found"
fi

# ==========================================
# Install additional tools
# ==========================================
echo ""
echo "Verifying installation..."

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Warning: jq is not installed. Some features may not work."
    echo "Please add jq RPM to $OFFLINE_PKG_DIR/rpm-packages/"
fi

# Retrieve the local IP address and set it for kubelet
# Note: Adjust interface name as needed (eth0, eth1, etc.)
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -n "$PRIMARY_INTERFACE" ]; then
    local_ip="$(ip --json addr show "$PRIMARY_INTERFACE" 2>/dev/null | jq -r '.[0].addr_info[] | select(.family == "inet") | .local' | head -n1)"
    
    if [ -n "$local_ip" ]; then
        # Write the local IP address to the kubelet default configuration file
        cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF
        echo "Kubelet configured with node IP: $local_ip"
    else
        echo "Warning: Could not determine local IP address"
    fi
else
    echo "Warning: Could not determine primary network interface"
fi

echo ""
echo "=========================================="
echo "Common setup completed successfully!"
echo "=========================================="
echo ""
echo "Installed components:"
echo "  - containerd: $(containerd --version 2>/dev/null || echo 'installed')"
echo "  - crictl: $(crictl --version 2>/dev/null || echo 'installed')"
echo "  - kubeadm: $(kubeadm version --short 2>/dev/null || echo 'installed')"
echo "  - kubelet: $(kubelet --version 2>/dev/null || echo 'installed')"
echo "  - kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
echo ""
