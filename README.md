# WireGuard Setup Script

This script automates the setup of WireGuard VPN on both VPS and client machines.

## Features
- Automatic WireGuard installation
- Key generation
- Configuration file creation
- iptables rules setup
- Systemd service management

## Example
<img src="example.svg" width="100%" />

## Prerequisites
- Ubuntu/Debian based system
- sudo privileges
- curl (for direct execution)

## Installation

### Download
1. run the script:
```bash
wget -q https://raw.githubusercontent.com/AlainDevs/wg-forwarding/refs/heads/master/setup.sh && chmod +x setup.sh && sudo ./setup.sh
```

## Usage

### VPS Setup
1. Run the script and choose option 1 (VPS)
2. The script will:
   - Install WireGuard
   - Generate VPS keys
   - Get external IP
   - Prompt for client public key
   - Create configuration
   - Set up iptables rules
   - Enable and start WireGuard service

### Client Setup
1. Run the script and choose option 2 (Client)
2. The script will:
   - Install WireGuard
   - Generate client keys
   - Prompt for VPS public key and external IP
   - Create configuration
   - Enable and start WireGuard service

## Security Considerations
- Keep private keys secure
- Use strong firewall rules
- Regularly update your system
- Consider using fail2ban for additional security

## Troubleshooting
- Check WireGuard status: `sudo systemctl status wg-quick@wg0`
- View logs: `journalctl -u wg-quick@wg0`
- Verify connection: `wg show`

## License
MIT License