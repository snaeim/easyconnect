#!/bin/bash

# Ensure the script is run as root
[ "$EUID" -eq 0 ] || {
    echo "Error: This script must be run as root. Exiting."
    exit 1
}

# Check if openconnect is installed
OCPATH=$(command -v openconnect)
[ -n "$OCPATH" ] || {
    echo "Error: 'openconnect' is not installed."
    echo "Install it using your package manager, e.g., 'apt install openconnect' or 'yum install openconnect'."
    exit 1
}

# Gather VPN connection details with immediate validation
echo "Please provide the following VPN connection details:"

# Get and validate VPN hostname
while :; do
    read -e -p "VPN server hostname (e.g., vpn.example.com): " VPN_HOST
    if [ -z "$VPN_HOST" ]; then
        echo "Error: The VPN hostname cannot be empty. Please try again."
    elif ! getent ahosts "$VPN_HOST" >/dev/null 2>&1; then
        echo "Error: The hostname '$VPN_HOST' could not be resolved. Please check your input."
    else
        break
    fi
done

# Get and validate VPN server IP address
VPN_ADDR_DEFAULT=$(getent ahosts "$VPN_HOST" | awk '{ print $1; exit }')
while :; do
    read -e -i "${VPN_ADDR_DEFAULT:-}" -p "VPN server IP address: " VPN_ADDR
    if [ -z "$VPN_ADDR" ]; then
        echo "Error: The VPN IP address cannot be empty. Please try again."
    else
        break
    fi
done

# Get and validate VPN port
while :; do
    read -e -i "443" -p "VPN server port: " VPN_PORT
    if [ -z "$VPN_PORT" ] || ! [[ "$VPN_PORT" =~ ^[0-9]+$ ]]; then
        echo "Error: The VPN port must be a valid number. Please try again."
    else
        break
    fi
done

# Get and validate VPN username
while :; do
    read -e -i "$(hostname -s)" -p "VPN username: " VPN_USER
    if [ -z "$VPN_USER" ]; then
        echo "Error: The VPN username cannot be empty. Please try again."
    else
        break
    fi
done

# Get and validate VPN password
while :; do
    read -sp "VPN password: " VPN_PASS
    echo
    if [ -z "$VPN_PASS" ]; then
        echo "Error: The VPN password cannot be empty. Please try again."
    else
        break
    fi
done

# Ask if a vpnc-script is needed
while true; do
    read -p "Set up a new routing table? (y/n): " RESPONSE
    if [[ "$RESPONSE" =~ ^[Yy]$ || "$RESPONSE" =~ ^[Nn]$ ]]; then
        break
    else
        echo "Invalid input. Please enter Y or N."
    fi
done

if [[ "$RESPONSE" =~ ^[Nn]$ ]]; then
    IFNAME=""
    VPNC_SCRIPT=""
    SERVICE_NAME="openconnect.service"
elif [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
    # Define reserved routing table IDs
    declare -A RESERVED_TABLES=(
        [255]="local"
        [254]="main"
        [253]="default"
        [0]="unspec"
    )

    # Get and validate TUN device name
    while :; do
        read -p "Enter TUN device name (e.g., tun0): " IFNAME
        if [ -z "$IFNAME" ]; then
            echo "Error: The TUN device name cannot be empty. Please try again."
        else
            break
        fi
    done

    # Proceed to routing table ID and name setup
    while true; do
        read -p "Enter routing table ID: " TABLE_ID
        # Check if it's a valid number
        if [[ -z "$TABLE_ID" || ! "$TABLE_ID" =~ ^[0-9]+$ ]]; then
            echo "Invalid input. Enter a numeric ID."
            continue
        fi
        # Check if the ID is reserved
        if [[ -n "${RESERVED_TABLES[$TABLE_ID]}" ]]; then
            echo "Error: ID '$TABLE_ID' is reserved for '${RESERVED_TABLES[$TABLE_ID]}'. Choose a different ID."
            continue
        fi
        break
    done

    while true; do
        read -p "Enter routing table name: " TABLE_NAME
        # Ensure the input is not empty and does not contain spaces
        if [[ -z "$TABLE_NAME" || "$TABLE_NAME" =~ \  ]]; then
            echo "Error: Routing table name cannot be empty or contain spaces. Please try again."
            continue
        fi
        # Check if TABLE_NAME is one of the reserved names
        if [[ " ${RESERVED_TABLES[@]} " == *" $TABLE_NAME "* ]]; then
            echo "Error: '$TABLE_NAME' is a reserved routing table name. Choose a different name."
            continue
        fi
        break
    done
    VPNC_DIR="/usr/share/vpnc-scripts"
    if [ ! -d "$VPNC_DIR" ]; then
        mkdir -p $VPNC_DIR
        chmod 755 $VPNC_DIR
    fi
    VPNC_SCRIPT="$VPNC_DIR/$IFNAME-default-$TABLE_NAME"
    SERVICE_NAME="openconnect-$IFNAME.service"
    cat <<EOF >$VPNC_SCRIPT
#!/bin/bash
#
# This script is used by VPN clients for managing the TUN tunnel device on modern Linux systems.
# Additionally, create a custom routing table for policy-based routing.
#
# Expected environment variables:
#   reason                 - Phase of connection (pre-init, connect, disconnect)
#   TUNDEV                 - Tunnel device name
#   INTERNAL_IP4_ADDRESS   - IPv4 address to assign (CIDR assumed /32)
#   INTERNAL_IP4_MTU       - (Optional) MTU to use; if unset the script calculates it
#   INTERNAL_IP6_ADDRESS   - (Optional) IPv6 address to assign
#   INTERNAL_IP6_NETMASK   - (Optional) IPv6 prefix length (e.g. 64)
#

# Set Bash Options
set -euo pipefail

# --- Define Policy Based Routing Table Variables ---
RT_TBL_ID=$TABLE_ID
RT_TBL_NAME=$TABLE_NAME
RT_TBL_FILE="/etc/iproute2/rt_tables"

# --- Functions ---
handle_error() {
    echo "Error: \$1" >&2
    exit 1
}

check_requirements() {
    # Check for required tools.
    for tool in ip modprobe awk; do
        command -v "\$tool" >/dev/null 2>&1 || handle_error "Required tool '\$tool' is not installed."
    done

    # Load the tun module if not already loaded.
    if ! lsmod | grep -q '^tun'; then
        modprobe tun || handle_error "Failed to load tun module."
    fi

    # Verify /dev/net/tun exists
    if [ ! -c /dev/net/tun ]; then
        handle_error "/dev/net/tun does not exist. Check your kernel configuration."
    fi

    # Ensure /dev/net/tun is accessible.
    local count=0
    while [ ! -r /dev/net/tun ] || [ ! -w /dev/net/tun ]; do
        if [ "\$count" -ge 10 ]; then
            handle_error "/dev/net/tun is not accessible. Check permissions."
        fi
        sleep 1
        count=\$((count + 1))
    done

    # Create a new routing table entry for the policy based routing if it doesn't already exist
    if ! grep -q "^\${RT_TBL_ID}[[:space:]]\${RT_TBL_NAME}" "\$RT_TBL_FILE"; then
        echo -e "\$RT_TBL_ID\t\$RT_TBL_NAME" >>"\$RT_TBL_FILE"
    fi
}

connect_tunnel() {
    # Define the default MTU range for TUN devices.
    local MTU=1412
    # Define the overhead for the TUN device(from original script).
    local OVERHEAD=88

    # Override MTU if INTERNAL_IP4_MTU is provided
    if [[ -n "\$INTERNAL_IP4_MTU" ]]; then
        MTU="\$INTERNAL_IP4_MTU"
    else
        # Determine the default network interface and get base MTU of default interface
        DEFAULT_IF=\$(ip route | awk '/^default/ {print \$5; exit}') || true
        if [[ -n "\$DEFAULT_IF" ]]; then
            BASE_MTU=\$(ip link show dev "\$DEFAULT_IF" | awk '/mtu/ {for(i=1;i<=NF;i++){ if (\$i=="mtu") {print \$(i+1); exit} } }') || true
            if [[ "\$BASE_MTU" =~ ^[0-9]+\$ ]]; then
                MTU=\$((BASE_MTU - OVERHEAD))
            fi
        fi
    fi

    # Flush existing IP addresses for existing devices or create a new TUN device.
    if ip link show "\$TUNDEV" >/dev/null 2>&1; then
        ip addr flush dev "\$TUNDEV" 2>/dev/null || handle_error "Failed to flush IP addresses from \$TUNDEV."
    else
        ip tuntap add dev "\$TUNDEV" mode tun 2>/dev/null || handle_error "Failed to create TUN device \$TUNDEV."
    fi

    # Bring up the TUN device with the calculated MTU.
    ip link set dev "\$TUNDEV" up mtu "\$MTU" || handle_error "Failed to bring up TUN device \$TUNDEV with MTU \$MTU."

    # Assign IPv4 and IPv6(if provided) addresses to the TUN device.
    ip addr add "\${INTERNAL_IP4_ADDRESS}/32" dev "\$TUNDEV" || handle_error "Failed to assign IPv4 address \${INTERNAL_IP4_ADDRESS}/32 to \$TUNDEV."
    if [[ -n "\${INTERNAL_IP6_ADDRESS:-}" && -n "\${INTERNAL_IP6_NETMASK:-}" ]]; then
        ip -6 addr add "\${INTERNAL_IP6_ADDRESS}/\${INTERNAL_IP6_NETMASK}" dev "\$TUNDEV" || {
            handle_error "Failed to assign IPv6 address \${INTERNAL_IP6_ADDRESS}/\${INTERNAL_IP6_NETMASK} to \$TUNDEV."
        }
    fi

    # Flush the routing table to remove any existing routes and add a default route via the TUN device.
    ip route flush table "\$RT_TBL_NAME" 2>/dev/null || true
    ip route add default dev "\$TUNDEV" scope link table "\$RT_TBL_NAME" || handle_error "Failed to add default route in table \$RT_TBL_NAME."
}

disconnect_tunnel() {
    # Check if the TUN device exists before attempting deletion.
    if ip link show "\$TUNDEV" >/dev/null 2>&1; then
        ip addr flush dev "\$TUNDEV" 2>/dev/null || true
        ip link set dev "\$TUNDEV" down 2>/dev/null || true
        ip tuntap del dev "\$TUNDEV" mode tun 2>/dev/null || true
    fi
}

main() {
    if [[ -z "\$reason" ]]; then
        handle_error "This script must be called from vpnc."
    fi

    case "\$reason" in
    pre-init)
        check_requirements
        ;;
    connect)
        connect_tunnel
        ;;
    disconnect)
        disconnect_tunnel
        ;;
    *)
        handle_error "Unknown reason: \$reason"
        ;;
    esac
}

main
exit 0
EOF
    chmod 755 $VPNC_SCRIPT
fi

# Define path to the systemd service file
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# Handle existing service
REMOVE_OLD="n"
[ -f "$SERVICE_FILE" ] && {
    echo "An existing OpenConnect service was detected."
    read -p "Do you want to replace the existing service? (y/n): " REMOVE_OLD
    if [[ ! "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
        echo "No changes made. Exiting."
        exit 0
    fi
}

# Stop, disable, and remove the existing OpenConnect VPN service if it exists
systemctl is-active --quiet "$SERVICE_NAME" && {
    echo "Stopping the existing OpenConnect VPN service..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
}
systemctl is-enabled --quiet "$SERVICE_NAME" && {
    echo "Disabling the OpenConnect VPN service..."
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
}
echo "Removing the OpenConnect VPN service file..."
rm -f "$SERVICE_FILE"

# OpenConnect options
OCOPTIONS=""
[ -n "$IFNAME" ] && OCOPTIONS+="--interface $IFNAME "
[ -n "$VPNC_SCRIPT" ] && OCOPTIONS+="--script $VPNC_SCRIPT "
OCOPTIONS+="--user $VPN_USER --passwd-on-stdin --resolve $VPN_HOST:$VPN_ADDR"

# Create systemd service file
cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=OpenConnect VPN Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment="PASSWD=$VPN_PASS"
ExecStart=/bin/bash -c 'echo \$PASSWD | ${OCPATH} ${OCOPTIONS} ${VPN_HOST}$([ "${VPN_PORT}" -eq 443 ] || echo ":${VPN_PORT}")'
ExecStop=/bin/bash -c '/bin/kill -SIGINT \$MAINPID'
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo "Service file created at $SERVICE_FILE."

# Reload systemd and enable the service
echo "Reloading systemd to register the new service..."
systemctl daemon-reload >/dev/null 2>&1 || {
    echo "Error: Failed to reload systemd. Ensure systemd is installed and functional."
}
echo "Enabling the OpenConnect service to start on boot..."
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
    echo "Error: Failed to enable the OpenConnect service. Check permissions or systemd configuration."
}
echo "Starting the OpenConnect service..."
systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || {
    echo "Error: Failed to start the OpenConnect service. Run 'sudo journalctl -u $SERVICE_NAME' for details."
}

# Final confirmation
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "The OpenConnect VPN service has been successfully created and started."
    echo "To check its status, run: sudo systemctl status $SERVICE_NAME"
else
    echo "Error: The OpenConnect VPN service failed to start. Check the system logs for details."
    echo "Run 'sudo journalctl -u $SERVICE_NAME' for debugging information."
fi