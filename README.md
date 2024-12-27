# easyconnect: OpenConnect VPN Connection Manager  

**easyconnect** simplifies the management of OpenConnect VPN connections on Linux systems. It provides two methods to ensure your VPN connection remains active and reconnects automatically if it disconnects.  

---

## Method 1: Systemd Service (Recommended)  

This method uses a **systemd service** to manage your VPN connection. It ensures the VPN starts at boot and automatically reconnects if it disconnects.  

### Setup  

Run the following command to generate and activate a systemd service for your OpenConnect VPN:  
```bash
sudo bash -c "$(wget -qO- https://prevue.ir/generate-openconnect-service.sh)"
```

## Method 2: Cron-based Script

This method uses a script that periodically checks your VPN connection and reconnects it if necessary.

### Setup  

Run the following commands to install the script:
```bash
sudo curl -Ls --output "/usr/local/bin/easyconnect" "http://prevue.ir/easyconnect.sh"
sudo chmod +x /usr/local/bin/easyconnect
```
To learn how to use the script, run:
```bash
sudo easyconnect help
```
