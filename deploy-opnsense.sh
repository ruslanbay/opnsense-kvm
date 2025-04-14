#!/bin/bash
set -e

# Configuration
OPNSENSE_VER="25.1"
IMG_DIR="${HOME}/VMs/images"
IMG_FILENAME="OPNsense-${OPNSENSE_VER}-serial-amd64.img"
IMG_PATH="${IMG_DIR}/${IMG_FILENAME}"
VM_NAME="opnsense"
RAM_MB=1024
CPUS=2
WLAN_IF="wlp0s20f3"
WAN_MAC="52:54:00:12:34:57"
LAN_BRIDGE="br-lan"
LAN_IP="192.168.100.1"
LAN_SUBNET="192.168.100.0/24"
LAN_MAC="52:54:00:12:34:56"
DISK_SIZE="5G"
DISK_PATH="${IMG_DIR}/${VM_NAME}.qcow2"
DOWNLOAD_URL="https://mirror.ams1.nl.leaseweb.net/opnsense/releases/${OPNSENSE_VER}/${IMG_FILENAME}.bz2"

# Ensure the user is running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "This script must be run as root! Use sudo."
    exit 1
fi

# # Cleanup function
# cleanup() {
#     echo "Cleaning up network interfaces..."
#     ip link del "$LAN_BRIDGE" 2>/dev/null || true
#     ip link del macvtap0 2>/dev/null || true
#     ip tuntap del tap0 mode tap 2>/dev/null || true
# }
# trap cleanup EXIT

# Check dependencies
check_dependencies() {
    # Check if QEMU/KVM is installed
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        echo "Installing QEMU/KVM core packages..."
        dnf install -y --setopt=install_weak_deps=FALSE qemu-kvm-core qemu-img

        # Load KVM kernel modules
        modprobe kvm kvm_intel 2>/dev/null || true

        # Add user to kvm group
        usermod -aG kvm "$SUDO_USER"
        echo "Please logout/login or reboot to apply group changes and ensure KVM is ready!"
        exit 1  # Exit to force user to re-login
    fi

    # Verify /dev/kvm exists and is accessible
    if [ ! -c /dev/kvm ]; then
        echo "ERROR: /dev/kvm not found. Ensure KVM is enabled in BIOS and kernel modules are loaded."
        exit 1
    fi
}

# Verify and download OPNsense image if needed
verify_iso() {
    if [ ! -f "$IMG_PATH" ]; then
        echo "Downloading OPNsense image..."
        mkdir -p "$IMG_DIR"
        curl -o "${IMG_PATH}.bz2" "$DOWNLOAD_URL"
        bzip2 -d "${IMG_PATH}.bz2"
    fi
}

# Create VM disk
create_disk() {
    if [ ! -f "$DISK_PATH" ]; then
        echo "Creating VM disk at $DISK_PATH..."
        mkdir -p "$IMG_DIR"
        qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    fi
}

# Setup network interfaces
setup_network_interfaces() {
    if ! ip link show "$LAN_BRIDGE" &> /dev/null; then
        # Create bridge for LAN interface
        ip link add name "$LAN_BRIDGE" type bridge
        ip link set "$LAN_BRIDGE" up
        ip addr add "$LAN_IP/24" dev "$LAN_BRIDGE"
        
        # Create tap interface for LAN
        ip tuntap add tap0 mode tap
        ip link set tap0 up
        ip link set tap0 master "$LAN_BRIDGE"
        
        # Create macvtap interface for WAN (in passthrough mode)
        ip link add link "$WLAN_IF" name macvtap0 type macvtap mode passthru
        ip link set macvtap0 up

        # Get the tap device name created by macvtap
        TAP_NUM=$(< /sys/class/net/macvtap0/ifindex)
        TAP_DEV="tap${TAP_NUM}"
        
        # Wait for tap device to be created
        sleep 2
        
        # Configure NAT for the LAN network
        sysctl -w net.ipv4.ip_forward=1
        iptables -t nat -A POSTROUTING -o "$WLAN_IF" -j MASQUERADE
        iptables -A FORWARD -i "$LAN_BRIDGE" -o "$WLAN_IF" -j ACCEPT
        iptables -A FORWARD -i "$WLAN_IF" -o "$LAN_BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        
        # Allow custom bridge
        # echo "allow $LAN_BRIDGE" | sudo tee -a /etc/qemu/bridge.conf
    fi
}

run_vm() {
    echo "Starting the VM..."
    qemu-system-x86_64 \
        -enable-kvm \
        -name "$VM_NAME" \
        -m "$RAM_MB" \
        -smp "$CPUS" \
        -drive id=hd0,file="$DISK_PATH",format=qcow2,if=none \
        -device virtio-blk-pci,drive=hd0,bootindex=1 \
        -drive id=hd1,file="$IMG_PATH",format=raw,if=none \
        -device virtio-blk-pci,drive=hd1 \
        -netdev tap,id=lan,ifname=tap0,script=no \
        -device virtio-net-pci,netdev=lan,mac="$LAN_MAC" \
        -netdev tap,id=wan,ifname="$TAP_DEV",script=no,downscript=no \
        -device virtio-net-pci,netdev=wan,mac="$WAN_MAC" \
        -nographic
}

# Route all traffic through the VM
route_traffic() {
    ip route del default 2>/dev/null || true
    ip route add default via "${LAN_IP%.*}.2" dev "$LAN_BRIDGE"
}

# Main function
main() {
    check_dependencies
    verify_iso
    create_disk
    setup_network_interfaces
    run_vm
    route_traffic
}

# Run the script
main