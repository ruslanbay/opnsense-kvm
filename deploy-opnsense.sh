#!/bin/bash
set -e

# Configuration
OPNSENSE_VER="25.1"
IMG_PATH="~/VMs/images/OPNsense-${OPNSENSE_VER}-serial-amd64.img"
VM_NAME="opnsense"
RAM_MB=1024
CPUS=2
WLAN_IF="wlp0s20f3"
LAN_BRIDGE="br-lan"
LAN_IP="192.168.100.1"
LAN_SUBNET="192.168.100.0/24"
DISK_SIZE="5G"
DISK_PATH="~/VMs/images/${VM_NAME}.qcow2"

# Ensure the user is running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "This script must be run as root! Use sudo."
    exit 1
fi

# Check dependencies
check_dependencies() {
    # Check if QEMU/KVM is installed
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        echo "Installing QEMU/KVM core packages..."
        sudo dnf install -y --setopt=install_weak_deps=FALSE qemu-kvm-core qemu-img

        # Load KVM kernel modules (Intel example)
        sudo modprobe kvm kvm_intel 2>/dev/null || true

        # Add user to kvm group
        sudo usermod -aG kvm "$USER"
        echo "Please logout/login or reboot to apply group changes and ensure KVM is ready!"
        exit 1  # Exit to force user to re-login
    fi

    # Verify /dev/kvm exists and is accessible
    if [ ! -c /dev/kvm ]; then
        echo "ERROR: /dev/kvm not found. Ensure KVM is enabled in BIOS and kernel modules are loaded."
        exit 1
    fi
}

# Verify ISO path
verify_iso() {
    if [ ! -f "$IMG_PATH" ]; then
        echo "OPNsense ISO not found at: $IMG_PATH"

        mkdir -p "$( dirname $IMG_PATH )"
        
        IMG_PATH="$( dirname $IMG_PATH )/OPNsense-${OPNSENSE_VER}-serial-amd64.img"

        curl -o "${IMG_PATH}.bz2" "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/${OPNSENSE_VER}/OPNsense-${OPNSENSE_VER}-serial-amd64.img.bz2"
        
        bzip2 -d "${IMG_PATH}.bz2"
    fi
}

# Create VM disk
create_disk() {
    if [ ! -f "$DISK_PATH" ]; then
        echo "Creating VM disk at $DISK_PATH..."
        mkdir -p "$(dirname "$DISK_PATH")"
        sudo qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    fi
}

# Setup network interfaces
setup_network_interfaces() {
    if ! ip link show "$LAN_BRIDGE" &> /dev/null; then
        # Create bridge for LAN interface
        sudo ip link add name $LAN_BRIDGE type bridge
        sudo ip link set $LAN_BRIDGE up
        sudo ip addr add $LAN_IP/24 dev $LAN_BRIDGE
        
        # Create tap interface for LAN
        sudo ip tuntap add tap0 mode tap
        sudo ip link set tap0 up
        sudo ip link set tap0 master $LAN_BRIDGE
        
        # Create macvtap interface for WAN (in passthrough mode)
        sudo ip link add link $WLAN_IF name macvtap0 type macvtap mode passthru
        sudo ip link set macvtap0 up

        # Get the tap device name created by macvtap
        TAP_NUM=$(< /sys/class/net/macvtap0/ifindex)
        TAP_DEV="tap${TAP_NUM}"
        
        # Wait for tap device to be created
        sleep 2
        
        # Configure NAT for the LAN network
        sudo sysctl -w net.ipv4.ip_forward=1
        sudo iptables -t nat -A POSTROUTING -o $WLAN_IF -j MASQUERADE
        sudo iptables -A FORWARD -i br-lan -o $WLAN_IF -j ACCEPT
        sudo iptables -A FORWARD -i $WLAN_IF -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT
        
        # Allow custom bridge
        # echo "allow $LAN_BRIDGE" | sudo tee -a /etc/qemu/bridge.conf
    fi
}

run_vm() {
    echo "Start the VM"
    sudo qemu-system-x86_64 \
        -enable-kvm \
        -name "$VM_NAME" \
        -m "$RAM_MB" \
        -smp "$CPUS" \
        -drive id=hd0,file="$DISK_PATH",format=qcow2,if=none \
        -device virtio-blk-pci,drive=hd0 \
        # -drive id=hd1,file="$IMG_PATH",format=raw,if=none \
        # -device virtio-blk-pci,drive=hd1,bootindex=1 \
        -netdev tap,id=lan,ifname=tap0,script=no \
        -device virtio-net-pci,netdev=lan,mac=52:54:00:12:34:56 \
        -netdev tap,id=wan,ifname=$TAP_DEV,script=no,downscript=no  \
        -device virtio-net-pci,netdev=wan,mac=52:54:00:12:34:57 \
        -nographic
}

# Route all traffic through the VM
route_traffic() {
    sudo ip route del default
    sudo ip route add default via ${LAN_IP%.*}.2 dev $LAN_BRIDGE  # LAN_IP="192.168.100.1"; ${LAN_IP%.*}.2 == 192.168.100.2
}

# Main function
main() {
    check_dependencies
    verify_iso
    create_disk
    setup_network_interfaces
    install_vm
    route_traffic
}

# Run the script
main
