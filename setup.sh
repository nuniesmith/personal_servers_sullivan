#!/bin/bash

# Setup script for a fresh install of Fedora Server 42
# This script handles Stage 1: updates, installations, and sets up a one-time systemd service for Stage 2 after reboot.
# Assumes .env is in the current directory with required secrets.

# Source the .env file
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found in current directory. Please create it with the required variables."
    exit 1
fi

# Copy .env to /tmp for Stage 2 to access post-reboot
sudo cp .env /tmp/.env

# Cache sudo credentials upfront
sudo -v

# Stage 1: Update the system
sudo dnf update -y

# Install jq for JSON parsing
sudo dnf install jq -y

# Install Tailscale
sudo dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo dnf install tailscale -y
sudo systemctl enable --now tailscaled

# Install Netdata with claim
wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && sh /tmp/netdata-kickstart.sh --nightly-channel --claim-token "${NETDATA_CLAIM_TOKEN}" --claim-rooms "${NETDATA_CLAIM_ROOMS}" --claim-url "${NETDATA_CLAIM_URL}"

# Install Docker Engine
sudo dnf remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine -y
sudo dnf install dnf-plugins-core -y
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
sudo systemctl enable --now docker

# Add user to docker group
sudo groupadd docker || true
sudo usermod -aG docker "${USER}"

# Configure Docker to not manage iptables (let firewalld handle)
echo '{"iptables": false}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# Create Stage 2 script (it will source /tmp/.env)
cat << 'EOF' | sudo tee /tmp/stage2.sh
#!/bin/bash

# Source the .env file from /tmp
if [ -f /tmp/.env ]; then
    source /tmp/.env
else
    echo "Error: /tmp/.env file not found. Stage 2 cannot proceed."
    exit 1
fi

# Get Tailscale API access token
ACCESS_TOKEN=$(curl -s -d "client_id=${TAILSCALE_CLIENT_ID}" \
                    -d "client_secret=${TAILSCALE_CLIENT_SECRET}" \
                    -d "grant_type=client_credentials" \
                    https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)

# Generate a one-time auth key
AUTH_KEY=$(curl -s -X POST \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{
                      "capabilities": {
                        "devices": {
                          "create": {
                            "reusable": false,
                            "ephemeral": false,
                            "preauthorized": true
                          }
                        }
                      },
                      "expirySeconds": 3600
                    }' \
                https://api.tailscale.com/api/v2/tailnet/-/keys | jq -r .key)

# Authenticate Tailscale
sudo tailscale up --authkey "${AUTH_KEY}" --hostname "${HOSTNAME}" --accept-routes --advertise-exit-node

# Setup basic firewall rules (allow SSH, reload firewalld)
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload

# Clean up the one-time service and files
sudo systemctl disable setup-stage2.service
rm /tmp/stage2.sh
rm /tmp/.env
EOF

# Make Stage 2 script executable
sudo chmod +x /tmp/stage2.sh

# Create one-time systemd service for Stage 2
cat << EOF | sudo tee /etc/systemd/system/setup-stage2.service
[Unit]
Description=Setup stage 2 after reboot
After=network.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/tmp/stage2.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Enable the service and reboot
sudo systemctl enable setup-stage2.service
sudo reboot