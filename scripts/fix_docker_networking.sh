#!/bin/bash

# Script to fix Docker networking issues when containers can't reach the internet
# This typically happens when Docker's iptables rules are missing or overridden

echo "Fixing Docker networking for Sullivan containers..."

# Get the Sullivan Docker network bridge name
SULLIVAN_BRIDGE=$(docker network inspect sullivan_default | jq -r '.[0].Id' | cut -c1-12)
SULLIVAN_BRIDGE="br-${SULLIVAN_BRIDGE}"

# Get the Sullivan network subnet
SULLIVAN_SUBNET=$(docker network inspect sullivan_default | jq -r '.[0].IPAM.Config[0].Subnet')

echo "Sullivan bridge: ${SULLIVAN_BRIDGE}"
echo "Sullivan subnet: ${SULLIVAN_SUBNET}"

# Add NAT/MASQUERADE rule for Docker containers
echo "Adding NAT rule for ${SULLIVAN_SUBNET}..."
sudo iptables -t nat -C POSTROUTING -s ${SULLIVAN_SUBNET} ! -o ${SULLIVAN_BRIDGE} -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s ${SULLIVAN_SUBNET} ! -o ${SULLIVAN_BRIDGE} -j MASQUERADE

# Add FORWARD rules
echo "Adding FORWARD rules..."
sudo iptables -C FORWARD -i ${SULLIVAN_BRIDGE} ! -o ${SULLIVAN_BRIDGE} -j ACCEPT 2>/dev/null || \
    sudo iptables -I FORWARD -i ${SULLIVAN_BRIDGE} ! -o ${SULLIVAN_BRIDGE} -j ACCEPT

sudo iptables -C FORWARD -o ${SULLIVAN_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    sudo iptables -I FORWARD -o ${SULLIVAN_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Testing connectivity..."
if docker exec sonarr ping -c 1 8.8.8.8 > /dev/null 2>&1; then
    echo "✅ Container internet connectivity restored!"
else
    echo "❌ Container connectivity still failing"
    exit 1
fi

echo "Docker networking fix complete."