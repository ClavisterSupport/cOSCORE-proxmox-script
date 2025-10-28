#!/bin/bash
# Ensure dependencies are installed
if ! command -v whiptail &>/dev/null; then
    echo "Installing whiptail..."
    apt-get update && apt-get install -y whiptail
fi

TEMP_FILE=""
OVA_EXTRACT_DIR="/tmp/ova_extract"

cleanup() {
    [[ -f "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
    [[ -d "$OVA_EXTRACT_DIR" ]] && rm -rf "$OVA_EXTRACT_DIR"
}
trap cleanup EXIT

whiptail --title "Clavister Firewall VM" --yesno "This will create a new Clavister Firewall VM. Proceed?" 10 50 || exit 1

# Clavister credentials
USERNAME=$(whiptail --title "https://my.clavister.com" --inputbox "Enter Clavister Username:" 10 50 "" 3>&1 1>&2 2>&3) || exit 1
PASSWORD=$(whiptail --title "https://my.clavister.com" --passwordbox "Enter Clavister Password:" 10 50 3>&1 1>&2 2>&3) || exit 1

# Deployment mode
DEPLOY_MODE=$(whiptail --title "Deployment Mode" --menu "Choose deployment mode:" 15 50 2 \
"1" "Single" \
"2" "High Availability (HA)" 3>&1 1>&2 2>&3) || exit 1

# List available bridges
BRIDGES=$(ip -o link show type bridge | awk -F': ' '{print $2}')
if [ -z "$BRIDGES" ]; then
    echo "❌ No bridges found on the system."
    exit 1
fi

# Function to select bridges for VM interfaces
select_bridges() {
    local iface_count=$1
    local -n arr=$2
    for i in $(seq 1 "$iface_count"); do
        OPTIONS=()
        COUNT=1
        for BR in $BRIDGES; do
            OPTIONS+=("$COUNT" "$BR")
            ((COUNT++))
        done
        SEL=$(whiptail --title "Select Bridge for Interface $i" --menu "Choose a bridge:" 15 50 5 \
            "${OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 1
        arr+=("$(echo "$BRIDGES" | sed -n "${SEL}p")")
    done
}

if [[ "$DEPLOY_MODE" == "2" ]]; then
    # HA mode
    VM_ID_MASTER=$(whiptail --inputbox "Enter Master VM ID:" 10 50 "9000" 3>&1 1>&2 2>&3) || exit 1
    VM_ID_SLAVE=$(whiptail --inputbox "Enter Slave VM ID:" 10 50 "9001" 3>&1 1>&2 2>&3) || exit 1
    VM_NAME_MASTER="clavister-firewall-master"
    VM_NAME_SLAVE="clavister-firewall-slave"
    INTERFACE_COUNT=$(whiptail --inputbox "Enter Number of Network Interfaces (min 2):" 10 50 "2" 3>&1 1>&2 2>&3) || exit 1

    if [[ "$VM_ID_MASTER" == "$VM_ID_SLAVE" ]]; then
        echo "❌ Master and Slave VM IDs must be different."
        exit 1
    fi
    if [[ "$INTERFACE_COUNT" -lt 2 ]]; then
        echo "❌ At least 2 interfaces are required for HA."
        exit 1
    fi

    # Create sync bridge
    SYNC_BRIDGE="Sync${VM_ID_MASTER}${VM_ID_SLAVE}"
    echo "Creating sync bridge: $SYNC_BRIDGE"
    if ! ip link show "$SYNC_BRIDGE" &>/dev/null; then
        ip link add name "$SYNC_BRIDGE" type bridge
        ip link set "$SYNC_BRIDGE" up
        ip link set "$SYNC_BRIDGE" promisc on
    fi

    # Select bridges for all interfaces except the first (sync bridge is auto for first)
    INTERFACES_BRIDGES=("$SYNC_BRIDGE")
    select_bridges $((INTERFACE_COUNT - 1)) INTERFACES_BRIDGES
else
    # Single VM mode
    VM_ID=$(whiptail --inputbox "Enter VM ID:" 10 50 "9000" 3>&1 1>&2 2>&3) || exit 1
    VM_NAME=$(whiptail --inputbox "Enter VM Name:" 10 50 "clavister-firewall" 3>&1 1>&2 2>&3) || exit 1
    INTERFACE_COUNT=$(whiptail --inputbox "Enter Number of Network Interfaces:" 10 50 "1" 3>&1 1>&2 2>&3) || exit 1

    INTERFACES_BRIDGES=()
    select_bridges "$INTERFACE_COUNT" INTERFACES_BRIDGES
fi

# Other VM settings
STORAGE=$(whiptail --inputbox "Enter Storage Location:" 10 50 "local-lvm" 3>&1 1>&2 2>&3) || exit 1
RAM_SIZE=$(whiptail --inputbox "Enter RAM Size (MB):" 10 50 "4096" 3>&1 1>&2 2>&3) || exit 1
CPU_CORES=$(whiptail --inputbox "Enter Number of CPU Cores:" 10 50 "4" 3>&1 1>&2 2>&3) || exit 1

# Firewall type
FIREWALL_TYPE=$(whiptail --title "Select Firewall Type" --menu "Choose an option:" 15 50 2 \
"1" "OVA" \
"2" "QCOW2" 3>&1 1>&2 2>&3) || exit 1

if [[ "$FIREWALL_TYPE" == "1" ]]; then
    FILE_URL="https://my.clavister.com/api/downloads/v1.0/file/a51dcf74-1cf5-ef11-a436-005056bdfeb0"
    FILE_NAME="clavister.ova"
else
    FILE_URL="https://my.clavister.com/api/downloads/v1.0/file/a31dcf74-1cf5-ef11-a436-005056bdfeb0"
    FILE_NAME="clavister.qcow2"
fi

# Get Bearer token
response=$(wget --quiet --method POST --header 'Content-Type: application/x-www-form-urlencoded' \
--body-data "username=$USERNAME&password=$PASSWORD&grant_type=password" -O - \
'https://my.clavister.com/api/oauth/v1.0/token')
bearer_token=$(echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
if [ -z "$bearer_token" ]; then echo "❌ Failed to retrieve token."; exit 1; fi

TEMP_FILE="/tmp/clavister_${FILE_NAME}"
if [[ ! -f "$TEMP_FILE" ]]; then
    echo "Downloading file..."
    wget --header "Authorization: Bearer $bearer_token" -O "$TEMP_FILE" "$FILE_URL" || exit 1
fi

convert_ova() {
    local vm_id=$1
    mkdir -p "/tmp/ova_extract"
    tar -xvf "$TEMP_FILE" -C "/tmp/ova_extract"
    local VMDK_FILE=$(find /tmp/ova_extract -name '*.vmdk' | head -n 1)
    [ -z "$VMDK_FILE" ] && echo "❌ VMDK not found." && exit 1
    qm importdisk "$vm_id" "$VMDK_FILE" "$STORAGE" --format qcow2
}

create_vm() {
    local vm_id=$1
    local vm_name=$2

    echo "Creating VM $vm_name..."
    # Assign first interface
    qm create "$vm_id" --name "$vm_name" --memory "$RAM_SIZE" --cores "$CPU_CORES" --net0 virtio,bridge="${INTERFACES_BRIDGES[0]}"

    # Assign remaining interfaces
    for i in $(seq 1 $((INTERFACE_COUNT - 1))); do
        qm set "$vm_id" --net$i virtio,bridge="${INTERFACES_BRIDGES[$i]}"
    done

    if [[ "$FIREWALL_TYPE" == "1" ]]; then
        convert_ova "$vm_id"
    else
        qm importdisk "$vm_id" "$TEMP_FILE" "$STORAGE" --format qcow2
    fi

    qm set "$vm_id" --virtio0 "$STORAGE:vm-${vm_id}-disk-0"
    qm resize "$vm_id" virtio0 4G
    qm set "$vm_id" --bios seabios
    qm set "$vm_id" --cpu host
    qm set "$vm_id" --boot order=virtio0
    qm set "$vm_id" --serial0 socket
    qm start "$vm_id"
}

# Create VM(s)
if [[ "$DEPLOY_MODE" == "2" ]]; then
    create_vm "$VM_ID_MASTER" "$VM_NAME_MASTER"
    create_vm "$VM_ID_SLAVE" "$VM_NAME_SLAVE"
else
    create_vm "$VM_ID" "$VM_NAME"
fi

echo "✅ Clavister VM(s) successfully created and started."
