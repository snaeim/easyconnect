# easyconnect

**The AnyConnect VPN client's management and automation are handled via a bash script.**

This script uses OpenConnect to connect to a VPN server with the AnyConnect protocol.

## Installation and usage

First, download the script to `/usr/local/bin` to make it globally available

`$ sudo curl -Ls --output "/usr/local/bin/easyconnect" "http://prevue.ir/easyconnect"`

Then, make the script executable

`$ sudo chmod +x /usr/local/bin/easyconnect`

To know how to use the script, read the full document with the blow command

`$ sudo easyconnect help`

tested on Ubuntu +18.04
