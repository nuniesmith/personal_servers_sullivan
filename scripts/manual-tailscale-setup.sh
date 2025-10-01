#!/bin/bash

# Manual Tailscale setup as alternative to OAuth
echo "=== Manual Tailscale Setup ==="

# Check if Tailscale is installed
if ! command -v tailscale &> /dev/null; then
    echo "Error: Tailscale is not installed. Run setup.sh first."
    exit 1
fi

echo "Starting Tailscale daemon..."
sudo systemctl enable --now tailscaled

echo ""
echo "To complete Tailscale setup manually:"
echo "1. Run: sudo tailscale up --hostname=sullivan --accept-routes --advertise-exit-node"
echo "2. Visit the login URL that appears"
echo "3. Authenticate in your browser"
echo ""
echo "This will connect your server to your Tailscale network."

# Optionally run the command interactively
read -p "Run Tailscale authentication now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo tailscale up --hostname=sullivan --accept-routes --advertise-exit-node
fi