#!/bin/bash

# Add logging for Stage 2
exec > >(tee -a /var/log/sullivan-setup-stage2.log)
exec 2>&1

echo "=== Sullivan Setup Stage 2 Started at $(date) ==="

# Source the .env file from /opt/sullivan-setup
if [ -f /opt/sullivan-setup/.env ]; then
    source /opt/sullivan-setup/.env
    echo "Successfully sourced .env file from /opt/sullivan-setup"
else
    echo "Error: /opt/sullivan-setup/.env file not found. Stage 2 cannot proceed."
    exit 1
fi

# Set hostname (default to sullivan if not specified in .env)
HOSTNAME=${HOSTNAME:-sullivan}
echo "Using hostname: $HOSTNAME"

# Check if Tailscale credentials are set
if [ -z "$TAILSCALE_CLIENT_ID" ] || [ -z "$TAILSCALE_CLIENT_SECRET" ]; then
    echo "Error: Tailscale credentials not found in .env file"
    echo "Please set TAILSCALE_CLIENT_ID and TAILSCALE_CLIENT_SECRET"
    exit 1
fi

echo "Tailscale Client ID: ${TAILSCALE_CLIENT_ID}"
echo "Tailscale Client Secret: ${TAILSCALE_CLIENT_SECRET:0:10}..." # Only show first 10 chars for security

# Get Tailscale API access token with better error handling
echo "Getting Tailscale API access token..."
API_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -d "client_id=${TAILSCALE_CLIENT_ID}" \
                    -d "client_secret=${TAILSCALE_CLIENT_SECRET}" \
                    -d "grant_type=client_credentials" \
                    https://api.tailscale.com/api/v2/oauth/token)

HTTP_CODE=$(echo "$API_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
API_BODY=$(echo "$API_RESPONSE" | sed '/HTTP_CODE:/d')

echo "API Response Code: $HTTP_CODE"
echo "API Response Body: $API_BODY"

if [ "$HTTP_CODE" != "200" ]; then
    echo "Error: Failed to get Tailscale access token (HTTP $HTTP_CODE)"
    echo "Response: $API_BODY"
    echo ""
    echo "This usually means:"
    echo "1. Invalid client credentials"
    echo "2. Credentials need to be regenerated in Tailscale admin console"
    echo "3. Network connectivity issues"
    echo ""
    echo "Please check your Tailscale OAuth client configuration at:"
    echo "https://login.tailscale.com/admin/settings/oauth"
    exit 1
fi

ACCESS_TOKEN=$(echo "$API_BODY" | jq -r .access_token)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "Error: Failed to parse access token from response"
    echo "Response: $API_BODY"
    exit 1
fi

echo "Successfully obtained Tailscale access token"

# Generate a one-time auth key with better error handling
echo "Generating Tailscale auth key..."
AUTH_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{
                      "capabilities": {
                        "devices": {
                          "create": {
                            "reusable": false,
                            "ephemeral": false,
                            "preauthorized": true,
                            "tags": ["tag:server"]
                          }
                        }
                      },
                      "expirySeconds": 3600
                    }' \
                https://api.tailscale.com/api/v2/tailnet/-/keys)

AUTH_HTTP_CODE=$(echo "$AUTH_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
AUTH_BODY=$(echo "$AUTH_RESPONSE" | sed '/HTTP_CODE:/d')

echo "Auth Key Response Code: $AUTH_HTTP_CODE"
echo "Auth Key Response Body: $AUTH_BODY"

if [ "$AUTH_HTTP_CODE" != "200" ]; then
    echo "Error: Failed to generate Tailscale auth key (HTTP $AUTH_HTTP_CODE)"
    echo "Response: $AUTH_BODY"
    exit 1
fi

AUTH_KEY=$(echo "$AUTH_BODY" | jq -r .key)

if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "null" ]; then
    echo "Error: Failed to parse auth key from response"
    echo "Response: $AUTH_BODY"
    exit 1
fi

echo "Successfully generated Tailscale auth key"

# Authenticate Tailscale
echo "Authenticating with Tailscale..."
if sudo tailscale up --authkey "${AUTH_KEY}" --hostname "${HOSTNAME}" --accept-routes --advertise-exit-node; then
    echo "Tailscale authentication successful!"
    
    # Show Tailscale status
    echo "Tailscale status:"
    sudo tailscale status
else
    echo "Error: Failed to authenticate with Tailscale"
    echo "This could be due to:"
    echo "1. Tailscale daemon not running"
    echo "2. Invalid auth key"
    echo "3. Network connectivity issues"
    
    # Show tailscale service status for debugging
    echo "Tailscale service status:"
    sudo systemctl status tailscaled --no-pager
    exit 1
fi

# Setup basic firewall rules (allow SSH, reload firewalld)
echo "Configuring firewall..."
sudo firewall-cmd --permanent --add-service=ssh || echo "Warning: Failed to add SSH service to firewall"
sudo firewall-cmd --reload || echo "Warning: Failed to reload firewall"

echo "=== Sullivan Setup Stage 2 Complete at $(date) ==="
echo "Tailscale authentication completed successfully"

# Clean up the one-time service and files
echo "Cleaning up setup files..."
sudo systemctl disable setup-stage2.service
rm -rf /opt/sullivan-setup
echo "Setup cleanup complete"