#!/usr/bin/env bash

# SULLIVAN stack startup script
# Inspired by FKS script: env detection, prereq checks, .env bootstrap, pull/up, and health checks

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"
COMPOSE_CMD=""

log(){
	local level="$1"; shift
	case "$level" in
		INFO)  echo -e "${GREEN}[INFO]${NC} $*" ;;
		WARN)  echo -e "${YELLOW}[WARN]${NC} $*" ;;
		ERROR) echo -e "${RED}[ERROR]${NC} $*" ;;
		DEBUG) echo -e "${BLUE}[DEBUG]${NC} $*" ;;
	esac
}

detect_environment(){
	if [[ -f /etc/cloud-id || -f /var/lib/cloud/data/instance-id || -n "${AWS_INSTANCE_ID:-}" || -n "${GCP_PROJECT:-}" || -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then echo cloud; return; fi
	if [[ -f /.dockerenv || -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then echo container; return; fi
	if command -v free >/dev/null 2>&1; then
		local mem; mem=$(free -m | awk '/^Mem:/{print $2}')
		if [[ -n "$mem" && "$mem" -lt 4096 ]]; then echo resource_constrained; return; fi
	fi
	local hn; hn=$(hostname || true)
	if [[ "$hn" =~ (dev|staging|cloud|vps|server) ]]; then echo dev_server; return; fi
	if [[ -f "$HOME/.laptop" || -f "$PROJECT_ROOT/.local" ]]; then echo laptop; return; fi
	echo laptop
}

DETECTED_ENV=$(detect_environment)

check_prerequisites(){
	log INFO "Checking prerequisites..."
	if ! command -v docker >/dev/null 2>&1; then log ERROR "Docker not installed"; exit 1; fi
	if ! docker info >/dev/null 2>&1; then log ERROR "Docker daemon not running"; exit 1; fi
	if command -v docker-compose >/dev/null 2>&1; then
		COMPOSE_CMD="docker-compose"
	elif docker compose version >/dev/null 2>&1; then
		COMPOSE_CMD="docker compose"
	else
		log ERROR "Docker Compose not available"; exit 1
	fi
	log INFO "Prerequisites OK"
}

create_env_file(){
	log INFO "Creating .env for SULLIVAN..."
	local tz puid pgid
	tz="${TZ:-America/Toronto}"
	puid=$(id -u); pgid=$(id -g)
	cat > "$ENV_FILE" <<EOF
# SULLIVAN environment
TZ=$tz
PUID=$puid
PGID=$pgid

	# Intel QuickSync / VAAPI (change if needed: iHD for newer Intel, i965 for older)
	LIBVA_DRIVER_NAME=iHD

# Paths (override if needed)
MEDIA_PATH=/mnt/media
MEDIA_PATH_MOVIES=/mnt/media/movies
MEDIA_PATH_SHOWS=/mnt/media/shows
MEDIA_PATH_MUSIC=/mnt/media/music
MEDIA_PATH_BOOKS=/mnt/media/books
DOWNLOAD_PATH_INCOMPLETE=/mnt/media/qbittorrent/incomplete
DOWNLOAD_PATH_COMPLETE=/mnt/media/qbittorrent/complete

# Optional API keys (fill in after first run)
SONARR_API_KEY=
RADARR_API_KEY=
LIDARR_API_KEY=
READARR_AUDIO_API_KEY=
READARR_EBOOKS_API_KEY=
DISCORD_TOKEN=

# Watchtower notifications (optional)
WATCHTOWER_NOTIFICATION_URL=
EOF
	log INFO ".env created at $ENV_FILE"
}

docker_network_sanity(){
	log INFO "Checking Docker networking..."
	if ! docker network ls >/dev/null 2>&1; then log ERROR "Docker not accessible"; exit 1; fi
	local testnet="sullivan-net-check-$$"
	if docker network create "$testnet" >/dev/null 2>&1; then
		docker network rm "$testnet" >/dev/null 2>&1 || true
		log INFO "Docker networking OK"
	else
		log WARN "Docker networking check failed; continuing"
	fi
}

pull_images(){
	log INFO "Pulling images..."
	$COMPOSE_CMD -f docker-compose.yml pull --ignore-pull-failures || true
}

start_stack(){
	log INFO "Starting SULLIVAN services..."
	$COMPOSE_CMD -f docker-compose.yml up -d
	log INFO "Waiting for services to initialize..."
	sleep 10
	$COMPOSE_CMD -f docker-compose.yml ps
}

stop_stack(){
	log INFO "Stopping SULLIVAN services..."
	$COMPOSE_CMD -f docker-compose.yml down --remove-orphans
}

health_checks(){
	log INFO "Running quick health checks..."
	# Open WebUI
	if curl -fsS http://localhost:3001/ >/dev/null 2>&1; then
		log INFO "Open WebUI: http://localhost:3001"
	else
		log WARN "Open WebUI not reachable yet"
	fi
	# Emby/Jellyfin/Plex
	if curl -fsS http://localhost:8096/ >/dev/null 2>&1; then log INFO "Emby: http://localhost:8096"; else log WARN "Emby not reachable yet"; fi
	if curl -fsS http://localhost:8097/ >/dev/null 2>&1; then log INFO "Jellyfin: http://localhost:8097"; else log WARN "Jellyfin not reachable yet"; fi
	if curl -fsS http://localhost:32400/web >/dev/null 2>&1; then log INFO "Plex: http://localhost:32400/web"; else log WARN "Plex not reachable yet"; fi
	# qBittorrent
	if curl -fsS http://localhost:8080/ >/dev/null 2>&1; then log INFO "qBittorrent: http://localhost:8080"; else log WARN "qBittorrent not reachable yet"; fi
	# Sonarr/Radarr/Lidarr
	if curl -fsS http://localhost:8989/ >/dev/null 2>&1; then log INFO "Sonarr: http://localhost:8989"; else log WARN "Sonarr not reachable yet"; fi
	if curl -fsS http://localhost:7878/ >/dev/null 2>&1; then log INFO "Radarr: http://localhost:7878"; else log WARN "Radarr not reachable yet"; fi
	if curl -fsS http://localhost:8686/ >/dev/null 2>&1; then log INFO "Lidarr: http://localhost:8686"; else log WARN "Lidarr not reachable yet"; fi
	# Misc apps
	if curl -fsS http://localhost:13378/ >/dev/null 2>&1; then log INFO "Audiobookshelf: http://localhost:13378"; fi
	if curl -fsS http://localhost:8084/ >/dev/null 2>&1; then log INFO "Calibre Web: http://localhost:8084"; fi
	if curl -fsS http://localhost:5452/ >/dev/null 2>&1; then log INFO "FileBot Node: http://localhost:5452"; fi
	if curl -fsS http://localhost:8200/ >/dev/null 2>&1; then log INFO "Duplicati: http://localhost:8200"; fi
	if curl -fsS http://localhost:9925/ >/dev/null 2>&1; then log INFO "Mealie: http://localhost:9925"; fi
	if curl -fsS http://localhost:9283/ >/dev/null 2>&1; then log INFO "Grocy: http://localhost:9283"; fi
	if curl -fsS http://localhost:8385/ >/dev/null 2>&1; then log INFO "Syncthing: http://localhost:8385"; fi
	if curl -fsS http://localhost:8090/ >/dev/null 2>&1; then log INFO "Wiki.js: http://localhost:8090"; fi
}

usage(){
	cat <<USAGE
SULLIVAN startup script

Usage: $(basename "$0") [options]
	--show-env        Print environment info and exit
	--stop            Stop and remove services
	--status          Show compose status
	--logs            Tail logs (Ctrl+C to exit)
	--no-pull         Do not pull images before start
	-h, --help        Show this help
USAGE
}

main(){
	local do_pull=1 action=start
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--show-env) action=showenv; shift ;;
			--stop) action=stop; shift ;;
			--status) action=status; shift ;;
			--logs) action=logs; shift ;;
			--no-pull) do_pull=0; shift ;;
			-h|--help) usage; exit 0 ;;
			*) log WARN "Unknown arg: $1"; usage; exit 1 ;;
		esac
	done

	check_prerequisites
	case "$action" in
		showenv)
			echo "Detected environment: $DETECTED_ENV"
			echo "Compose: ${COMPOSE_CMD}"
			if command -v free >/dev/null 2>&1; then echo "Memory: $(free -m | awk '/^Mem:/{print $2}') MB"; fi
			exit 0 ;;
		stop)
			stop_stack; exit 0 ;;
		status)
			$COMPOSE_CMD -f docker-compose.yml ps; exit 0 ;;
		logs)
			$COMPOSE_CMD -f docker-compose.yml logs -f; exit 0 ;;
	esac

	cd "$PROJECT_ROOT"
	[[ -f "$ENV_FILE" ]] || create_env_file

	$COMPOSE_CMD -f docker-compose.yml down --remove-orphans >/dev/null 2>&1 || true
	docker_network_sanity

	(( do_pull )) && pull_images
	start_stack
	health_checks

	log INFO "Done. Common endpoints:"
	echo "  Open WebUI:     http://localhost:3001"
	echo "  Emby:           http://localhost:8096"
	echo "  Jellyfin:       http://localhost:8097"
	echo "  Plex:           http://localhost:32400/web"
	echo "  qBittorrent:    http://localhost:8080"
	echo "  Sonarr:         http://localhost:8989"
	echo "  Radarr:         http://localhost:7878"
	echo "  Lidarr:         http://localhost:8686"
}

main "$@"

