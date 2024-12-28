#!/bin/bash

# Function to install WireGuard
install_wireguard() {
    echo "Installing WireGuard..."
    sudo apt update
    sudo apt install wireguard -y
    echo "WireGuard installed."
}

# Function to generate keys
generate_keys() {
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    echo "Private Key: $private_key"
    echo "Public Key: $public_key"
}

# Function to get the external IP address
get_external_ip() {
    external_ip=$(curl -4 -s ifconfig.me)
    echo "External IPv4 Address: $external_ip"
}

# Function to write the VPS configuration
write_vps_config() {
    cat <<EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1
PrivateKey = $vps_private_key
ListenPort = 51820

[Peer]
PublicKey = $client_public_key
AllowedIPs = 10.0.0.2/32
EOF
}

# Function to write the client configuration
write_client_config() {
    cat <<EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.2
PrivateKey = $client_private_key

[Peer]
PublicKey = $vps_public_key
Endpoint = $vps_external_ip:51820
#AllowedIPs = 0.0.0.0/0
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
EOF
}

# Function to set up iptables rules on the VPS
setup_iptables() {
    echo "Setting up iptables rules..."
    sudo apt install iptables-persistent -y
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -X
    sudo iptables -t nat -X

    # Allow SSH traffic to the VPS (do not forward it)
    sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # Allow WireGuard traffic to the VPS (do not forward it)
    sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT

    # Forward all TCP traffic (except SSH and WireGuard ports) to the client
    sudo iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 22 -j RETURN
    sudo iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 51820 -j RETURN
    sudo iptables -t nat -A PREROUTING -i eth0 -p tcp -j DNAT --to-destination 10.0.0.2

    # Forward all UDP traffic (except WireGuard port) to the client
    sudo iptables -t nat -A PREROUTING -i eth0 -p udp --dport 51820 -j RETURN
    sudo iptables -t nat -A PREROUTING -i eth0 -p udp -j DNAT --to-destination 10.0.0.2

    # Allow forwarded traffic
    sudo iptables -A FORWARD -i eth0 -o wg0 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    sudo iptables -A FORWARD -i wg0 -o eth0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Masquerade outgoing traffic
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    # Save the rules to make them persistent
    sudo iptables-save | sudo tee /etc/iptables/rules.v4
    echo "iptables rules configured."
}

# Main script
echo "Choose an option:"
echo "1. VPS"
echo "2. Client"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        echo "Setting up VPS..."
        install_wireguard
        echo "Generating VPS keys..."
        generate_keys
        vps_private_key=$private_key
        vps_public_key=$public_key
        echo "VPS Public Key: $vps_public_key"
        echo
        get_external_ip
        vps_external_ip=$external_ip
        echo "VPS External IP: $vps_external_ip"
        echo
        read -p "Enter the client's public key: " client_public_key
        echo "Writing VPS configuration..."
        write_vps_config
        echo "Setting up iptables rules..."
        setup_iptables
        echo "Starting WireGuard..."
        sudo systemctl enable wg-quick@wg0
        sudo systemctl start wg-quick@wg0
        
        # Enable IP forwarding
        echo "Enabling IP forwarding..."
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
        echo "IP forwarding enabled."
        
        echo "VPS setup complete!"
        ;;
    2)
        echo "Setting up Client..."
        install_wireguard
        echo "Generating Client keys..."
        generate_keys
        client_private_key=$private_key
        client_public_key=$public_key
        echo "Client Public Key: $client_public_key"
        echo
        read -p "Enter the VPS's public key: " vps_public_key
        read -p "Enter the VPS's external IPv4 address: " vps_external_ip
        echo "Writing Client configuration..."
        write_client_config
        echo "Starting WireGuard..."
        sudo systemctl enable wg-quick@wg0
        sudo systemctl start wg-quick@wg0
        echo "Client setup complete!"
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "Setup complete!"
