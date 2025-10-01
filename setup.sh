# Setup script for a fresh install of Fedora Server 42

# First fully update the server with dnf, make sure we ask for sudo credentials up front, and once we run this script, we can reboot the system, updates to kernel and other modules need a restart.
# Sometimes its best to setup firewall rules and other things after fully updating the system and rebooting after the updates. If we need to run tasks after the reboot,
# we can create a systemd service to run once at boot to finish setup tasks.
sudo dnf update -y

# Tailscale

sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo dnf install tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
tailscale ip -4 = true
sudo tailscale up --authkey tskey-********** --hostname sullivan --accept-routes --advertise-exit-node

TAILSCALE_CLIENT_ID=kxLeP41NZ921CNTRL
TAILSCALE_CLIENT_SECRET=tskey-client-kxLeP41NZ921CNTRL-d9iyJEJ4HrL4rJwB5QPrqLtp2xnPUdjVc

# Setup netdata
wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && sh /tmp/netdata-kickstart.sh --nightly-channel --claim-token Sn5D3zsAEX9KA_YtztxjdHCpan6v-oHfy1OKUrAIGNciXf4T_w0CiqCZc0b7jL7sk_OH8uAA9O7o3Z7XjzHjV8Z2xDySPaSxspzRyb1R3G77mmQVvkCKp5KDHIL9UX7wVDpylrU --claim-rooms 9d87b8a7-72d7-4886-a471-57d2970f9bc2 --claim-url https://app.netdata.cloud

NETDATA_CLAIM_TOKEN=Sn5D3zsAEX9KA_YtztxjdHCpan6v-oHfy1OKUrAIGNciXf4T_w0CiqCZc0b7jL7sk_OH8uAA9O7o3Z7XjzHjV8Z2xDySPaSxspzRyb1R3G77mmQVvkCKp5KDHIL9UX7wVDpylrU
NETDATA_CLAIM_URL=https://app.netdata.cloud
NETDATA_CLAIM_ROOMS=9d87b8a7-72d7-4886-a471-57d2970f9bc2

# Docker Engine

