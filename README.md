# EasyConnect

## Overview

EasyConnect is a bash script solution that simplifies OpenConnect VPN configuration on Linux systems. The script provides an interactive approach to setting up secure network connections with advanced routing capabilities, supporting both IPv4 and IPv6 environments.

## Features

- Interactive VPN configuration wizard
- Automatic systemd service generation
- Policy-based routing support
- Custom routing table creation
- Dynamic MTU configuration
- IPv4 and IPv6 address support
- Automatic VPN service management
- Boot-time VPN connection
- Automatic connection restart
- System journal logging

## Requirements

- Linux system with systemd
- OpenConnect installed
- Root/sudo access

## Installation and Usage

When running the service generator, you'll be prompted for VPN details:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/snaeim/easyconnect/refs/heads/main/wizard.sh)"
```

### Detailed Configuration Process

When you run the script, you'll be asked to provide:

1. VPN server hostname
2. VPN server IP address
3. VPN server port
4. VPN username
5. VPN password
6. Optional: Create a new routing table
   - If yes, you'll be asked to specify:
     - TUN device name
     - Routing table ID
     - Routing table name

## Note

Ensure you have the necessary permissions and network access to connect to your VPN server.