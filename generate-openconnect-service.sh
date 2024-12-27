#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root. Exiting."
  exit 1
fi

# Check if openconnect is installed
OPENCONNECT_PATH=$(command -v openconnect)
if [ -z "$OPENCONNECT_PATH" ]; then
  echo "Error: 'openconnect' is not installed."
  echo "Install it using your package manager, e.g., 'apt install openconnect' or 'yum install openconnect'."
  exit 1
fi

# Define service name and the path to the systemd service file
SERVICE_NAME="openconnect.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# Handle existing service
REMOVE_OLD="n"
if [ -f "$SERVICE_FILE" ]; then
  echo "An existing OpenConnect service was detected."
  read -p "Do you want to replace the existing service? (y/n): " REMOVE_OLD
  if [[ ! "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
    echo "No changes made. Exiting."
    exit 0
  fi
fi

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

# Stop, disable, and remove the existing OpenConnect VPN service if it exists
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "Stopping the existing OpenConnect VPN service..."
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
fi  
if systemctl is-enabled --quiet "$SERVICE_NAME"; then
  echo "Disabling the OpenConnect VPN service..."
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
fi
echo "Removing the OpenConnect VPN service file..."
rm -f "$SERVICE_FILE"

# Create the service file
echo "Creating the OpenConnect VPN systemd service..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=OpenConnect VPN Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment="HOST=$VPN_HOST"
Environment="ADDR=$VPN_ADDR"
Environment="PORT=$VPN_PORT"
Environment="USER=$VPN_USER"
Environment="PASS=$VPN_PASS"
ExecStart=/bin/bash -c 'echo \$PASS | $OPENCONNECT_PATH --user \$USER --passwd-on-stdin --resolve \$HOST:\$ADDR \$HOST:\$PORT'
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
if ! systemctl daemon-reload >/dev/null 2>&1; then
  echo "Error: Failed to reload systemd. Ensure systemd is installed and functional."
  exit 1
fi
echo "Enabling the OpenConnect service to start on boot..."
if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "Error: Failed to enable the OpenConnect service. Check permissions or systemd configuration."
  exit 1
fi
echo "Starting the OpenConnect service..."
if ! systemctl start "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "Error: Failed to start the OpenConnect service. Run 'sudo journalctl -u $SERVICE_NAME' for details."
  exit 1
fi

# Final confirmation
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "The OpenConnect VPN service has been successfully created and started."
  echo "To check its status, run: sudo systemctl status $SERVICE_NAME"
else
  echo "Error: The OpenConnect VPN service failed to start. Check the system logs for details."
  echo "Run 'sudo journalctl -u $SERVICE_NAME' for debugging information."
fi