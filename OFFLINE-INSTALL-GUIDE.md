# Offline Kubernetes Installation Guide for ARM/EulerOS

This guide explains how to install Kubernetes on ARM-based EulerOS servers without internet access.

## Overview

The offline installation process consists of three main steps:
1. **Download packages** on an internet-connected machine
2. **Transfer packages** to offline servers
3. **Install Kubernetes** using local packages

## Prerequisites

### On Internet-Connected Machine
- Docker installed (for pulling and saving container images)
- curl, wget for downloading files
- Same architecture as target servers (ARM64/aarch64)

### On Offline Servers (EulerOS ARM)
- SSH access
- Sudo privileges
- At least 2GB RAM, 2 CPU cores
- Network connectivity between servers

## Step 1: Download Packages (Internet-Connected Machine)

Run the download script on a machine with internet access:

```bash
# Make the script executable
chmod +x scripts/download-packages.sh

# Run the download script
./scripts/download-packages.sh
```

This will create an `offline-packages/` directory containing:
- `binaries/` - kubeadm, kubelet, kubectl, crictl
- `container-images/` - Kubernetes and Calico container images
- `calico-manifests/` - Calico network plugin YAML files
- `rpm-packages/` - Placeholder for RPM packages (see below)

### Downloading RPM Packages for EulerOS

The script creates a list of required RPM packages. You need to manually download these from EulerOS repositories:

```bash
# On a EulerOS machine with internet access
mkdir -p offline-packages/rpm-packages

# Download required packages
yum install --downloadonly --downloaddir=offline-packages/rpm-packages \
    containerd \
    curl \
    jq \
    socat \
    conntrack-tools \
    ipset \
    ipvsadm \
    ebtables \
    ethtool
```

**Required RPM packages:**
- containerd (container runtime)
- curl (HTTP client)
- jq (JSON processor)
- socat (networking tool)
- conntrack-tools (connection tracking)
- ipset (IP sets)
- ipvsadm (IPVS administration)
- ebtables (Ethernet bridge tables)
- ethtool (Ethernet settings)

## Step 2: Transfer Packages to Offline Servers

Copy the entire `offline-packages/` directory to your offline servers:

```bash
# Using scp
scp -r offline-packages/ user@server1:/home/user/

# Or using rsync
rsync -avz offline-packages/ user@server1:/home/user/offline-packages/

# Or compress and transfer
tar czf offline-packages.tar.gz offline-packages/
scp offline-packages.tar.gz user@server1:/home/user/
```

## Step 3: Install Kubernetes on Offline Servers

### On Master Node

```bash
# Set the offline package directory
export OFFLINE_PKG_DIR=/path/to/offline-packages

# Make scripts executable
chmod +x scripts/common-offline.sh
chmod +x scripts/master-offline.sh

# Run common setup (installs containerd, Kubernetes binaries, loads images)
sudo -E ./scripts/common-offline.sh

# Initialize the master node
sudo -E ./scripts/master-offline.sh
```

**Note:** The `-E` flag preserves environment variables when using sudo.

### On Worker Nodes

```bash
# Set the offline package directory
export OFFLINE_PKG_DIR=/path/to/offline-packages

# Make scripts executable
chmod +x scripts/common-offline.sh

# Run common setup
sudo -E ./scripts/common-offline.sh

# Join the cluster (get this command from master node)
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

## Configuration Options

### Environment Variables

- `OFFLINE_PKG_DIR` - Path to offline packages directory (default: `./offline-packages`)

### Network Interface

The scripts auto-detect the primary network interface. If you need to specify a different interface, edit the scripts and change the interface detection logic.

### Pod CIDR

Default Pod CIDR is `192.168.0.0/16`. To change it, edit `master-offline.sh`:

```bash
POD_CIDR="10.244.0.0/16"  # Change to your preferred CIDR
```

## Verification

After installation, verify the cluster:

```bash
# Check node status
kubectl get nodes -o wide

# Check all pods are running
kubectl get pods -A

# Check cluster info
kubectl cluster-info

# Check component status
kubectl get componentstatuses
```

## Troubleshooting

### Container Images Not Loading

If container images fail to load:

```bash
# Check containerd is running
sudo systemctl status containerd

# Manually load images
for img in offline-packages/container-images/*.tar; do
    sudo ctr -n k8s.io images import "$img"
done

# List loaded images
sudo ctr -n k8s.io images ls
```

### RPM Installation Issues

If RPM packages fail to install:

```bash
# Install with dependencies
sudo yum localinstall -y offline-packages/rpm-packages/*.rpm

# Or install individually
sudo rpm -Uvh offline-packages/rpm-packages/*.rpm --nodeps
```

### Kubernetes Services Not Starting

Check logs:

```bash
# Check kubelet logs
sudo journalctl -u kubelet -f

# Check containerd logs
sudo journalctl -u containerd -f

# Check kubeadm logs
sudo journalctl -u kubelet --since "10 minutes ago"
```

### Reset Installation

To reset and start over:

```bash
# Reset kubeadm
sudo kubeadm reset -f

# Remove Kubernetes packages
sudo rpm -e kubeadm kubelet kubectl

# Clean container images
sudo ctr -n k8s.io images rm $(sudo ctr -n k8s.io images ls -q)

# Restart containerd
sudo systemctl restart containerd
```

## File Structure

```
offline-packages/
├── binaries/
│   ├── kubeadm
│   ├── kubelet
│   ├── kubectl
│   └── crictl.tar.gz
├── container-images/
│   ├── registry.k8s.io_kube-apiserver_v1.34.tar
│   ├── registry.k8s.io_kube-controller-manager_v1.34.tar
│   ├── registry.k8s.io_kube-scheduler_v1.34.tar
│   ├── registry.k8s.io_kube-proxy_v1.34.tar
│   ├── registry.k8s.io_pause_3.10.tar
│   ├── registry.k8s.io_etcd_3.5.21-0.tar
│   ├── registry.k8s.io_coredns_coredns_v1.12.0.tar
│   └── calico-*.tar
├── calico-manifests/
│   ├── operator-crds.yaml
│   ├── tigera-operator.yaml
│   └── custom-resources.yaml
├── rpm-packages/
│   ├── containerd-*.rpm
│   ├── jq-*.rpm
│   └── ...
├── package-list.txt
└── checksums.txt
```

## Architecture Support

The scripts automatically detect and support:
- **ARM64/aarch64** - For ARM-based servers
- **AMD64/x86_64** - For x86-based servers

## Security Considerations

1. **Verify checksums** after transferring packages:
   ```bash
   cd offline-packages
   sha256sum -c checksums.txt
   ```

2. **Secure transfer** - Use encrypted transfer methods (scp, rsync over SSH)

3. **File permissions** - Ensure proper permissions on kubeconfig:
   ```bash
   chmod 600 ~/.kube/config
   ```

## Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Calico Documentation](https://docs.tigera.io/calico/latest/about/)
- [EulerOS Documentation](https://docs.openeuler.org/)

## Support

For issues specific to:
- **Kubernetes**: Check [Kubernetes GitHub Issues](https://github.com/kubernetes/kubernetes/issues)
- **Calico**: Check [Calico GitHub Issues](https://github.com/projectcalico/calico/issues)
- **EulerOS**: Check [EulerOS Documentation](https://docs.openeuler.org/)
