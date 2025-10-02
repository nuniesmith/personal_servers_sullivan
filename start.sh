#!/usr/bin/env bash

# SULLIVAN stack startup script
# Media & Intensive Services - powerful server handling media, downloads, AI, and user applications
# Uses single docker-compose.yml with comprehensive service definitions

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# List of services in dependency order (databases first, then base services, then dependent services)
SERVICES=(
	# Database services (must start first)
	"ytdl-mongo-db" "wiki-postgres"
	# AI services
	"ollama" "open-webui"
	# Download infrastructure
	"qbittorrent" "jackett" "flaresolverr"
	# Media management (ARR stack - depends on qbittorrent/jackett)
	"sonarr" "radarr" "lidarr" "readarr.audio" "readarr.ebooks"
	# Post-processing (depends on ARR stack)
	"unpackerr" "doplarr"
	# Media servers
	"emby" "jellyfin" "plex" "audiobookshelf"
	# Book management
	"calibre" "calibre-web"
	# Utility services
	"filebot-node" "ytdl_material" "duplicati" "mealie" "grocy" "syncthing" "wiki"
	# Monitoring (last)
	"watchtower"
)

COMPOSE_CMD=""

log() {
	local level="$1"; shift
	case "$level" in
		INFO)  echo -e "${GREEN}[INFO]${NC} $*" ;;
		WARN)  echo -e "${YELLOW}[WARN]${NC} $*" ;;
		ERROR) echo -e "${RED}[ERROR]${NC} $*" ;;
		DEBUG) echo -e "${BLUE}[DEBUG]${NC} $*" ;;
	esac
}

detect_environment() {
	# Cloud/container markers
	if [[ -f /etc/cloud-id || -f /var/lib/cloud/data/instance-id || -n "${AWS_INSTANCE_ID:-}" || -n "${GCP_PROJECT:-}" || -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
		echo cloud; return
	fi
	if [[ -f /.dockerenv || -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
		echo container; return
	fi
	# Memory check
	if command -v free >/dev/null 2>&1; then
		local mem; mem=$(free -m | awk '/^Mem:/{print $2}')
		if [[ -n "$mem" && "$mem" -lt 2048 ]]; then echo resource_constrained; return; fi
	fi
	# Hostname heuristic
	local hn; hn=$(hostname || true)
	if [[ "$hn" =~ (dev|staging|cloud|vps|server) ]]; then echo dev_server; return; fi
	# Markers
	if [[ -f "$HOME/.laptop" || -f "$PROJECT_ROOT/.local" ]]; then echo laptop; return; fi
	echo laptop
}

DETECTED_ENV=$(detect_environment)

check_prerequisites() {
	log INFO "Checking prerequisites..."
	if ! command -v docker >/dev/null 2>&1; then
		log ERROR "Docker is not installed"; exit 1
	fi
	if ! docker info >/dev/null 2>&1; then
		log ERROR "Docker daemon is not running"; exit 1
	fi
	if command -v docker-compose >/dev/null 2>&1; then
		COMPOSE_CMD="docker-compose"
	elif docker compose version >/dev/null 2>&1; then
		COMPOSE_CMD="docker compose"
	else
		log ERROR "Docker Compose is not available"; exit 1
	fi
	log INFO "Prerequisites OK"
}

# Generate secure random secrets
generate_secret() {
	local length="${1:-32}"
	# Use openssl if available, otherwise use /dev/urandom
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$((length/2))"
	else
		head -c "$length" /dev/urandom | base64 | tr -d '=+/' | head -c "$length"
	fi
}

# Generate API key (32 characters)
generate_api_key() {
	generate_secret 32
}

# Generate password (16 characters, alphanumeric)
generate_password() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -base64 12 | tr -d '=+/' | head -c 16
	else
		head -c 12 /dev/urandom | base64 | tr -d '=+/' | head -c 16
	fi
}

# Update environment variable in .env file
update_env_var() {
	local env_file="$1"
	local var_name="$2"
	local var_value="$3"
	
	# Create backup
	cp "$env_file" "$env_file.bak"
	
	# Check if variable already has a real value (not placeholder)
	local current_value
	current_value=$(grep "^${var_name}=" "$env_file" | cut -d'=' -f2- || echo "")
	
	# Skip if already has a real value (not a placeholder)
	if [[ -n "$current_value" && "$current_value" != "your_"*"_here" && "$current_value" != "changeme_"* ]]; then
		log INFO "$var_name already has a value, skipping"
		return
	fi
	
	# Update the variable
	if grep -q "^${var_name}=" "$env_file"; then
		sed -i "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
	else
		echo "${var_name}=${var_value}" >> "$env_file"
	fi
	log INFO "Generated $var_name"
}

# Function to extract API key from service logs (future enhancement)
fetch_api_key_from_logs() {
	local service_name="$1"
	local container_name="$2"
	
	# This is a placeholder for future implementation
	# Different ARR services log their API keys in different ways
	case "$service_name" in
		sonarr|radarr|lidarr)
			# Example: docker logs could contain API key information
			# This would need service-specific parsing logic
			log INFO "API key extraction from logs not yet implemented for $service_name"
			log INFO "Please copy manually from $service_name settings"
			;;
	esac
}

# Generate all required secrets and update .env file
generate_and_update_secrets() {
	local env_file; env_file=$(get_env_file)
	
	if [[ ! -f "$env_file" ]]; then
		log ERROR ".env file not found at $env_file"
		return 1
	fi
	
	log INFO "Generating secrets and updating .env file..."
	
	# Set API key placeholders (actual keys must be copied from each service's settings after startup)
	update_env_var "$env_file" "SONARR_API_KEY" "COPY_FROM_SONARR_SETTINGS_AFTER_STARTUP"
	update_env_var "$env_file" "RADARR_API_KEY" "COPY_FROM_RADARR_SETTINGS_AFTER_STARTUP"
	update_env_var "$env_file" "LIDARR_API_KEY" "COPY_FROM_LIDARR_SETTINGS_AFTER_STARTUP"
	
	# Generate database passwords
	update_env_var "$env_file" "WIKI_DB_PASSWORD" "$(generate_password)"
	update_env_var "$env_file" "MEALIE_DB_PASSWORD" "$(generate_password)"
	
	# Generate FileBot password (user remains 'admin')
	update_env_var "$env_file" "FILEBOT_PASSWORD" "$(generate_password)"
	
	# Generate Discord token placeholder (user will need to get real token from Discord)
	update_env_var "$env_file" "DISCORD_TOKEN" "PLACEHOLDER_$(generate_secret 40)_GET_REAL_TOKEN_FROM_DISCORD"
	
	log INFO "Secret generation complete!"
	log WARN "NOTE: ARR API keys must be copied manually from each service after startup:"
	log WARN "      - Sonarr: http://localhost:8989/settings/general"
	log WARN "      - Radarr: http://localhost:7878/settings/general" 
	log WARN "      - Lidarr: http://localhost:8686/settings/general"
	log WARN "NOTE: DISCORD_TOKEN is a placeholder. Get your real bot token from Discord Developer Portal."
}

# Function to get compose file (single file for Sullivan)
get_compose_file() {
    echo "$PROJECT_ROOT/docker-compose.yml"
}

# Function to get env file (single .env file for Sullivan)
get_env_file() {
    echo "$PROJECT_ROOT/.env"
}

create_env_files() {
	log INFO "Checking .env file..."
	
	local env_file; env_file=$(get_env_file)
	if [[ -f "$env_file" ]]; then
		log INFO ".env file already exists at $env_file"
		return
	fi

	log WARN ".env file not found. Sullivan requires a pre-configured .env file."
	log INFO "Please ensure your .env file exists with all required variables for:"
	log INFO "  - Media paths (MEDIA_PATH_*, DOWNLOAD_PATH_*)"
	log INFO "  - API keys (SONARR_API_KEY, RADARR_API_KEY, etc.)"
	log INFO "  - Database passwords (WIKI_DB_PASSWORD, MEALIE_DB_PASSWORD)"
	log INFO "  - Discord bot token (DISCORD_TOKEN) for Doplarr"
	log INFO "  - Other service-specific configurations"
	log INFO ""
	log INFO "Example .env file structure is available in the repository."
	
	# Create a basic .env file with defaults
	log INFO "Creating basic .env file with defaults..."
	cat > "$env_file" <<EOF
# =============================================================================
# CORE SETTINGS (Used across multiple services)
# =============================================================================
TZ=America/Toronto
PUID=1000
PGID=100
LIBVA_DRIVER_NAME=iHD

# =============================================================================
# MEDIA PATHS (Mount points for media libraries)
# =============================================================================
MEDIA_PATH=/mnt/media
MEDIA_PATH_MOVIES=/mnt/media/movies
MEDIA_PATH_SHOWS=/mnt/media/shows
MEDIA_PATH_MUSIC=/mnt/media/music
MEDIA_PATH_BOOKS=/mnt/media/books
MEDIA_PATH_AUDIOBOOKS=/mnt/media/books/audiobooks
MEDIA_PATH_EBOOKS=/mnt/media/ebooks

# =============================================================================
# DOWNLOAD PATHS
# =============================================================================
DOWNLOAD_PATH_COMPLETE=/mnt/media/qbittorrent/complete
DOWNLOAD_PATH_INCOMPLETE=/mnt/media/qbittorrent/incomplete

# =============================================================================
# API KEYS (Copy from each service's Settings -> General -> API Key after startup)
# =============================================================================
SONARR_API_KEY=COPY_FROM_SONARR_SETTINGS_AFTER_STARTUP
RADARR_API_KEY=COPY_FROM_RADARR_SETTINGS_AFTER_STARTUP
LIDARR_API_KEY=COPY_FROM_LIDARR_SETTINGS_AFTER_STARTUP

# =============================================================================
# FILEBOT SETTINGS
# =============================================================================
FILEBOT_USER=admin
FILEBOT_PASSWORD=changeme_filebot_password

# =============================================================================
# DISCORD/DOPLARR SETTINGS
# =============================================================================
DISCORD_TOKEN=your_discord_bot_token_here

# =============================================================================
# DATABASE PASSWORDS
# =============================================================================
WIKI_DB_PASSWORD=changeme_wiki_password
MEALIE_DB_PASSWORD=changeme_mealie_password

# =============================================================================
# WATCHTOWER SETTINGS
# =============================================================================
WATCHTOWER_SCHEDULE="0 2 * * *"
WATCHTOWER_NOTIFICATION_URL=

EOF

	log WARN "Basic .env file created. Please update with your actual API keys and passwords!"
	log INFO "Generated basic .env at $env_file"
	
	# Generate secrets automatically
	generate_and_update_secrets
}

check_media_paths() {
    log INFO "Checking media directory structure..."
    
    # Load environment variables
    local env_file; env_file=$(get_env_file)
    if [[ -f "$env_file" ]]; then
        source "$env_file"
    fi
    
    # Check critical media paths
    local media_paths=(
        "${MEDIA_PATH:-/mnt/media}"
        "${MEDIA_PATH_MOVIES:-/mnt/media/movies}"
        "${MEDIA_PATH_SHOWS:-/mnt/media/shows}"
        "${MEDIA_PATH_MUSIC:-/mnt/media/music}"
        "${MEDIA_PATH_BOOKS:-/mnt/media/books}"
        "${DOWNLOAD_PATH_COMPLETE:-/mnt/media/qbittorrent/complete}"
        "${DOWNLOAD_PATH_INCOMPLETE:-/mnt/media/qbittorrent/incomplete}"
    )
    
    local missing_paths=()
    for path in "${media_paths[@]}"; do
        if [[ ! -d "$path" ]]; then
            missing_paths+=("$path")
        fi
    done
    
    if [[ ${#missing_paths[@]} -gt 0 ]]; then
        log WARN "Missing media directories:"
        for path in "${missing_paths[@]}"; do
            log WARN "  - $path"
        done
        log INFO "Please create these directories or update your .env file paths"
        log INFO "Services may fail to start without proper media paths"
    else
        log INFO "Media directory structure looks good"
    fi
}

show_environment_info() {
	echo "Detected environment: $DETECTED_ENV"
	echo "Compose: ${COMPOSE_CMD:-not detected}"
	echo "System: hostname=$(hostname) user=$USER"
	if command -v free >/dev/null 2>&1; then
		echo "Memory: $(free -m | awk '/^Mem:/{print $2}') MB"
	fi
}

docker_network_sanity() {
	log INFO "Checking Docker networking..."
	if ! docker network ls >/dev/null 2>&1; then
		log ERROR "Docker not accessible"; exit 1
	fi
	local testnet="sullivan-net-check-$$"
	if docker network create "$testnet" >/dev/null 2>&1; then
		docker network rm "$testnet" >/dev/null 2>&1 || true
		log INFO "Docker networking OK"
	else
		log WARN "Docker networking check failed; continuing"
	fi
}

create_directories() {
    local target_services=("${@}")
    log INFO "Checking Sullivan data directories..."
    
    # Load environment variables
    local env_file; env_file=$(get_env_file)
    if [[ -f "$env_file" ]]; then
        source "$env_file"
    fi
    
    # Sullivan uses named volumes for most data, but we need to ensure media paths exist
    local critical_dirs=(
        "${MEDIA_PATH:-/mnt/media}"
        "${MEDIA_PATH_MOVIES:-/mnt/media/movies}"
        "${MEDIA_PATH_SHOWS:-/mnt/media/shows}"
        "${MEDIA_PATH_MUSIC:-/mnt/media/music}"
        "${MEDIA_PATH_BOOKS:-/mnt/media/books}"
        "${MEDIA_PATH_AUDIOBOOKS:-/mnt/media/books/audiobooks}"
        "${MEDIA_PATH_EBOOKS:-/mnt/media/ebooks}"
        "${DOWNLOAD_PATH_COMPLETE:-/mnt/media/qbittorrent/complete}"
        "${DOWNLOAD_PATH_INCOMPLETE:-/mnt/media/qbittorrent/incomplete}"
        "${YOUTUBE_AUDIO_PATH:-/mnt/media/youtube/audio}"
        "${YOUTUBE_VIDEO_PATH:-/mnt/media/youtube/video}"
    )

    for dir in "${critical_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if mkdir -p "$dir" 2>/dev/null; then
                log INFO "Created $dir"
            else
                log WARN "Failed to create $dir - check permissions"
            fi
        fi
        
        # Set permissions if running as root and we have PUID/PGID
        if [[ $EUID -eq 0 && -n "${PUID:-}" && -n "${PGID:-}" ]]; then
            chown -R "${PUID}:${PGID}" "$dir" 2>/dev/null || log WARN "Failed to chown $dir"
        fi
    done

    log INFO "Directory check complete"
}

# Build compose command for Sullivan (single compose file)
build_compose_cmd() {
    local target_services=("${@}")
    
    # Sullivan uses single compose file and env file
    local compose_file; compose_file=$(get_compose_file)
    local env_file; env_file=$(get_env_file)
    
    echo "-f $compose_file --env-file $env_file"
}

pull_images() {
    local target_services=("${@}")
	log INFO "Pulling images for ${target_services[*]}..."
	local cmd_args; cmd_args=$(build_compose_cmd "${target_services[@]}")
	$COMPOSE_CMD $cmd_args pull --ignore-pull-failures || true
}

start_stack() {
    local target_services=("${@}")
    create_directories "${target_services[@]}"
	log INFO "Starting SULLIVAN services: ${target_services[*]}..."
	local cmd_args; cmd_args=$(build_compose_cmd "${target_services[@]}")
	
	# Start specific services or all services
	if [[ ${#target_services[@]} -eq ${#SERVICES[@]} ]]; then
		# Starting all services
		$COMPOSE_CMD $cmd_args up -d
	else
		# Starting specific services
		$COMPOSE_CMD $cmd_args up -d "${target_services[@]}"
	fi
	
	log INFO "Waiting for services to initialize..."
	sleep 10
	$COMPOSE_CMD $cmd_args ps
}

stop_stack() {
    local target_services=("${@}")
	log INFO "Stopping SULLIVAN services: ${target_services[*]}..."
	local cmd_args; cmd_args=$(build_compose_cmd "${target_services[@]}")
	
	if [[ ${#target_services[@]} -eq ${#SERVICES[@]} ]]; then
		# Stopping all services
		$COMPOSE_CMD $cmd_args down --remove-orphans
	else
		# Stopping specific services
		$COMPOSE_CMD $cmd_args stop "${target_services[@]}"
	fi
}

health_checks() {
    local target_services=("${@}")
	log INFO "Running quick health checks for ${target_services[*]}..."
	for service in "${target_services[@]}"; do
		case "$service" in
			# Media Services
			emby)
				if curl -fsS http://localhost:8096 >/dev/null 2>&1; then
					log INFO "Emby: http://localhost:8096"
				else
					log WARN "Emby not reachable yet"
				fi
				;;
			jellyfin)
				if curl -fsS http://localhost:8097 >/dev/null 2>&1; then
					log INFO "Jellyfin: http://localhost:8097"
				else
					log WARN "Jellyfin not reachable yet"
				fi
				;;
			plex)
				if curl -fsS http://localhost:32400/web >/dev/null 2>&1; then
					log INFO "Plex: http://localhost:32400"
				else
					log WARN "Plex not reachable yet"
				fi
				;;
			audiobookshelf)
				if curl -fsS http://localhost:13378 >/dev/null 2>&1; then
					log INFO "Audiobookshelf: http://localhost:13378"
				else
					log WARN "Audiobookshelf not reachable yet"
				fi
				;;
			# Download Management
			qbittorrent)
				if curl -fsS http://localhost:8080 >/dev/null 2>&1; then
					log INFO "qBittorrent: http://localhost:8080"
				else
					log WARN "qBittorrent not reachable yet"
				fi
				;;
			sonarr)
				if curl -fsS http://localhost:8989 >/dev/null 2>&1; then
					log INFO "Sonarr: http://localhost:8989"
				else
					log WARN "Sonarr not reachable yet"
				fi
				;;
			radarr)
				if curl -fsS http://localhost:7878 >/dev/null 2>&1; then
					log INFO "Radarr: http://localhost:7878"
				else
					log WARN "Radarr not reachable yet"
				fi
				;;
			lidarr)
				if curl -fsS http://localhost:8686 >/dev/null 2>&1; then
					log INFO "Lidarr: http://localhost:8686"
				else
					log WARN "Lidarr not reachable yet"
				fi
				;;
			jackett)
				if curl -fsS http://localhost:9117 >/dev/null 2>&1; then
					log INFO "Jackett: http://localhost:9117"
				else
					log WARN "Jackett not reachable yet"
				fi
				;;
			# Utility Services
			mealie)
				if curl -fsS http://localhost:9925 >/dev/null 2>&1; then
					log INFO "Mealie: http://localhost:9925"
				else
					log WARN "Mealie not reachable yet"
				fi
				;;
			wiki)
				if curl -fsS http://localhost:8090 >/dev/null 2>&1; then
					log INFO "Wiki.js: http://localhost:8090"
				else
					log WARN "Wiki.js not reachable yet"
				fi
				;;
			# Database checks
			wiki-postgres)
				if docker exec wiki-postgres pg_isready -U wikijs >/dev/null 2>&1; then
					log INFO "Wiki Postgres: healthy"
				else
					log WARN "Wiki Postgres not ready yet"
				fi
				;;
			ytdl-mongo-db)
				if docker exec mongo-db mongosh --eval "db.runCommand('ping')" >/dev/null 2>&1; then
					log INFO "MongoDB: healthy"
				else
					log WARN "MongoDB not ready yet"
				fi
				;;
		esac
	done
}

usage() {
	cat <<USAGE
SULLIVAN startup script - Media & Intensive Services

Usage: $(basename "$0") [options] [service]
	service: all (default) or specific services like:
	  Media: emby, jellyfin, plex, audiobookshelf, calibre, calibre-web
	  Downloads: qbittorrent, jackett, sonarr, radarr, lidarr, readarr.audio, readarr.ebooks
	  Utils: mealie, wiki, grocy, syncthing, duplicati, filebot-node, ytdl_material
	  Databases: ytdl-mongo-db, wiki-postgres
	  Monitoring: watchtower

Options:
	--show-env        Print environment info and exit
	--stop            Stop and remove services
	--status          Show compose status
	--logs            Tail logs (Ctrl+C to exit)
	--no-pull         Do not pull images before start
	--generate-secrets Generate and update secrets in .env file
	-h, --help        Show this help
USAGE
}

main() {
	local do_pull=1 action=start target_service="all"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--show-env)        action=showenv; shift ;;
			--stop)            action=stop; shift ;;
			--status)          action=status; shift ;;
			--logs)            action=logs; shift ;;
			--no-pull)         do_pull=0; shift ;;
			--generate-secrets) action=generate_secrets; shift ;;
			-h|--help)         usage; exit 0 ;;
			*) 
				if [[ " ${SERVICES[*]} all " =~ " $1 " ]]; then
					target_service="$1"; shift
				else
					log WARN "Unknown arg: $1"; usage; exit 1
				fi
				;;
		esac
	done

	check_prerequisites
	case "$action" in
		showenv)
			show_environment_info; exit 0 ;;
		generate_secrets)
			cd "$PROJECT_ROOT"
			create_env_files  # Create .env if it doesn't exist
			generate_and_update_secrets
			log INFO "Secrets generated and updated in .env file"
			exit 0 ;;
	esac

	cd "$PROJECT_ROOT"
	create_env_files

	local target_services=()
	if [[ "$target_service" == "all" ]]; then
		target_services=("${SERVICES[@]}")
	else
		target_services=("$target_service")
	fi

	# Clean and sanity check
	local cmd_args; cmd_args=$(build_compose_cmd "${target_services[@]}")
	$COMPOSE_CMD $cmd_args down --remove-orphans >/dev/null 2>&1 || true
	docker_network_sanity

	# Sullivan uses default bridge network for simplicity
	docker_network_sanity
	check_media_paths

	case "$action" in
		stop)
			stop_stack "${target_services[@]}"; exit 0 ;;
		status)
			$COMPOSE_CMD $cmd_args ps; exit 0 ;;
		logs)
			$COMPOSE_CMD $cmd_args logs -f; exit 0 ;;
	esac

	(( do_pull )) && pull_images "${target_services[@]}"
	start_stack "${target_services[@]}"
	health_checks "${target_services[@]}"

	log INFO "Done. SULLIVAN services started successfully!"
	echo ""
	echo "=== Common Service Endpoints ==="
	echo "Media Servers:"
	echo "  Emby:            http://localhost:8096"
	echo "  Jellyfin:        http://localhost:8097"
	echo "  Plex:            http://localhost:32400"
	echo "  Audiobookshelf:  http://localhost:13378"
	echo ""
	echo "Download Management:"
	echo "  qBittorrent:     http://localhost:8080"
	echo "  Sonarr:          http://localhost:8989"
	echo "  Radarr:          http://localhost:7878"
	echo "  Lidarr:          http://localhost:8686"
	echo "  Jackett:         http://localhost:9117"
	echo ""
	echo "Utilities:"
	echo "  Mealie:          http://localhost:9925"
	echo "  Wiki.js:         http://localhost:8090"
	echo "  Grocy:           http://localhost:9283"
	echo "  Duplicati:       http://localhost:8200"
}

main "$@"