#!/bin/bash
set -euo pipefail # Exit on error, undefined variable, or pipe failure

# --- Global Variables (will be set by functions) ---
private_key=""
public_key=""
vps_private_key=""
vps_public_key=""
client_private_key=""
client_public_key=""
external_ip=""
public_interface="" # For VPS

# --- Helper Functions ---

# Check if the script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Please use 'sudo ./script_name.sh'." >&2
        exit 1
    fi
    echo "Running as root."
}

# Function to install WireGuard
install_wireguard() {
    echo "Updating package list..."
    apt-get update
    echo "Installing WireGuard and prerequisite tools (curl, iptables-persistent)..."
    apt-get install wireguard curl iptables-persistent -y
    echo "WireGuard and tools installed."
}

# Function to generate WireGuard keys
generate_keys_for_role() {
    local role_name="$1"
    echo "Generating ${role_name} keys..."
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    echo "${role_name} Private Key: $private_key"
    echo "${role_name} Public Key: $public_key"
}

# Function to get the public network interface and IP address (for VPS)
get_network_info() {
    echo "Detecting public network interface and IP address..."
    # Get the default public interface name
    public_interface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$public_interface" ]; then
        echo "Could not reliably determine the public network interface. Please set it manually." >&2
        # Fallback or prompt if needed, for now we exit.
        # read -p "Please enter the public network interface (e.g., eth0, ens3): " public_interface
        # if [ -z "$public_interface" ]; then echo "Aborting." >&2; exit 1; fi
        exit 1
    fi

    # Get the external IP address
    external_ip=$(curl -4 -s ifconfig.me)
    if [ -z "$external_ip" ]; then
        echo "Could not determine the external IP address. Exiting." >&2
        exit 1
    fi

    echo "Public Interface: $public_interface"
    echo "External IPv4 Address: $external_ip"
}

# Function to write the VPS WireGuard configuration
write_vps_config() {
    echo "Writing VPS WireGuard configuration to /etc/wireguard/wg0.conf..."
    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
PrivateKey = $vps_private_key
ListenPort = 51820
# PostUp and PostDown rules can be added here for a more self-contained config
# Example:
# PostUp = iptables -t nat -A POSTROUTING -o wg0 -d 10.0.0.2 -p tcp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1; iptables -t nat -A POSTROUTING -o wg0 -d 10.0.0.2 -p udp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $public_interface -j MASQUERADE
# PostDown = iptables -t nat -D POSTROUTING -o wg0 -d 10.0.0.2 -p tcp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1; iptables -t nat -D POSTROUTING -o wg0 -d 10.0.0.2 -p udp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o $public_interface -j MASQUERADE

[Peer]
# Client
PublicKey = $client_public_key
AllowedIPs = 10.0.0.2/32
EOF
    echo "VPS configuration written."
}

# Function to write the client WireGuard configuration
write_client_config() {
    local client_config_filename="client-wg0.conf"
    echo "Writing Client WireGuard configuration to $PWD/$client_config_filename..."
    cat <<EOF > "$client_config_filename"
[Interface]
Address = 10.0.0.2/32
PrivateKey = $client_private_key
# Optional: Add DNS for the client if they use the tunnel for some DNS resolution
# DNS = 1.1.1.1

[Peer]
# VPS
PublicKey = $vps_public_key
Endpoint = $vps_external_ip:51820
AllowedIPs = 10.0.0.1/32 # Client only routes traffic destined for VPS's WG IP via tunnel
PersistentKeepalive = 25
EOF
    echo "Client configuration written to $PWD/$client_config_filename"
    echo "Please copy this file to your client machine (e.g., to /etc/wireguard/wg0.conf or import into WG client)."
}

# Function to set up iptables rules and IP forwarding on the VPS
setup_vps_firewall_and_forwarding() {
    echo "Setting up iptables rules and IP forwarding for interface: $public_interface"

    # Flush existing rules to start fresh (use with caution on a live server if you have other rules)
    echo "Flushing existing iptables rules..."
    iptables -F
    iptables -X
    iptables -Z
    iptables -t nat -F
    iptables -t nat -X
    iptables -t nat -Z
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -t mangle -Z
    # Raw table flush might be too aggressive, usually not needed unless specific raw rules exist
    # iptables -t raw -F
    # iptables -t raw -X
    # iptables -t raw -Z

    # Set default policies (safer: DROP and allow explicitly)
    echo "Setting default iptables policies (INPUT/FORWARD: DROP, OUTPUT: ACCEPT)..."
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT # Allow outgoing connections from the VPS itself

    # --- INPUT Chain (traffic destined for the VPS itself) ---
    iptables -A INPUT -i lo -j ACCEPT # Allow loopback traffic
    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT # Allow returning traffic for established connections

    # Allow SSH
    iptables -A INPUT -i "$public_interface" -p tcp --dport 22 -j ACCEPT
    # Allow WireGuard
    iptables -A INPUT -i "$public_interface" -p udp --dport 51820 -j ACCEPT

    # --- FORWARD Chain (traffic passing through the VPS) ---
    # Allow established and related traffic for connections already approved/DNATed
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # Allow NEW forwarded traffic from public internet to client via WireGuard for specified ports
    iptables -A FORWARD -i "$public_interface" -o wg0 -d 10.0.0.2 -p tcp -m multiport --dports 5000:40000 -m conntrack --ctstate NEW -j ACCEPT
    iptables -A FORWARD -i "$public_interface" -o wg0 -d 10.0.0.2 -p udp -m multiport --dports 5000:40000 -m conntrack --ctstate NEW -j ACCEPT

    # --- NAT Table ---
    # PREROUTING: DNAT for incoming traffic to be forwarded to the client
    echo "Adding DNAT rules for ports 5000-40000 to 10.0.0.2..."
    iptables -t nat -A PREROUTING -i "$public_interface" -p tcp -m multiport --dports 5000:40000 -j DNAT --to-destination 10.0.0.2
    iptables -t nat -A PREROUTING -i "$public_interface" -p udp -m multiport --dports 5000:40000 -j DNAT --to-destination 10.0.0.2

    # POSTROUTING: SNAT for traffic going TO the client over wg0 (source becomes VPS's WG IP)
    # This ensures client replies to 10.0.0.1, correctly using the tunnel.
    echo "Adding SNAT rules for traffic forwarded to client via wg0..."
    iptables -t nat -A POSTROUTING -o wg0 -d 10.0.0.2 -p tcp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1
    iptables -t nat -A POSTROUTING -o wg0 -d 10.0.0.2 -p udp -m multiport --dports 5000:40000 -j SNAT --to-source 10.0.0.1

    # POSTROUTING: General MASQUERADE for any traffic from WG subnet (10.0.0.0/24) going out public interface.
    # This is for scenarios where the client might route other traffic via VPS (not the primary case here).
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$public_interface" -j MASQUERADE

    # Enable IP forwarding
    echo "Enabling IP forwarding in /etc/sysctl.conf..."
    if grep -q "^#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    elif ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    echo "Applying sysctl changes..."
    sysctl -p
    echo "IP forwarding enabled."

    # Save the rules to make them persistent
    echo "Saving iptables rules..."
    netfilter-persistent save
    echo "iptables rules configured and saved."
}

# --- Main Script ---
echo "WireGuard Setup Script"
echo "======================"
echo "Choose an option:"
echo "  1. Setup this machine as VPS (Server)"
echo "  2. Generate Client configuration (and optionally install WireGuard)"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        # --- VPS SETUP ---
        echo
        echo "--- Setting up VPS ---"
        check_root
        install_wireguard
        
        generate_keys_for_role "VPS"
        vps_private_key=$private_key
        vps_public_key=$public_key
        echo "VPS Public Key: $vps_public_key"
        echo "(Save this key for the client configuration)"
        echo

        get_network_info # Sets $public_interface and $external_ip globally
        
        echo
        read -p "Enter the Client's WireGuard Public Key: " client_public_key_input
        if [ -z "$client_public_key_input" ]; then
            echo "Client public key cannot be empty. Exiting." >&2
            exit 1
        fi
        client_public_key=$client_public_key_input # Assign to global

        write_vps_config # Uses global $vps_private_key, $client_public_key
        setup_vps_firewall_and_forwarding # Uses global $public_interface
        
        echo "Starting and enabling WireGuard service (wg-quick@wg0)..."
        systemctl enable wg-quick@wg0
        systemctl restart wg-quick@wg0 # Use restart to ensure it picks up new config
        
        echo
        echo "✅ VPS setup complete!"
        echo "   Forwarding TCP/UDP ports 5000-40000 from $external_ip ($public_interface)"
        echo "   to client at WireGuard IP 10.0.0.2."
        echo "   Ensure your cloud provider's firewall also allows these ports to the VPS."
        ;;
    2)
        # --- CLIENT SETUP ---
        echo
        echo "--- Setting up Client ---"
        # Ask if user wants to install WireGuard on this machine (if it's the client)
        read -p "Do you want to install WireGuard on this machine? (y/N): " install_wg_client
        if [[ "$install_wg_client" =~ ^[Yy]$ ]]; then
            check_root # install_wireguard needs root
            install_wireguard
        fi

        generate_keys_for_role "Client"
        client_private_key=$private_key
        client_public_key=$public_key # This is the key the VPS needs
        echo "Client Public Key: $client_public_key"
        echo "(Provide this key to the VPS setup)"
        echo

        read -p "Enter the VPS's WireGuard Public Key: " vps_public_key_input
        read -p "Enter the VPS's external IPv4 address (e.g., $(curl -4 -s ifconfig.me 2>/dev/null || echo "1.2.3.4")): " vps_external_ip_input
        if [ -z "$vps_public_key_input" ] || [ -z "$vps_external_ip_input" ]; then
            echo "VPS public key and IP address cannot be empty. Exiting." >&2
            exit 1
        fi
        vps_public_key=$vps_public_key_input     # Assign to global
        vps_external_ip=$vps_external_ip_input # Assign to global

        write_client_config # Uses global $client_private_key, $vps_public_key, $vps_external_ip
        
        if [[ "$install_wg_client" =~ ^[Yy]$ ]]; then
            echo "To use the generated configuration '$PWD/client-wg0.conf':"
            echo "1. Copy it: sudo cp $PWD/client-wg0.conf /etc/wireguard/wg0.conf"
            echo "2. Enable service: sudo systemctl enable wg-quick@wg0"
            echo "3. Start service: sudo systemctl start wg-quick@wg0"
        fi
        echo
        echo "✅ Client configuration generation complete!"
        ;;
    *)
        echo "Invalid choice. Exiting." >&2
        exit 1
        ;;
esac

echo
echo "Setup finished."
