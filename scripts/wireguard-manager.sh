#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────

WG_DIR="/root/linux-all/selfhosted/docker/wireguard"
CONFIG_DIR="$WG_DIR/config"
WG_CONFS="$CONFIG_DIR/wg_confs"
CLIENT_CONFS="$CONFIG_DIR/client_confs"
KEYS_DIR="$CONFIG_DIR/keys"
SERVER_CONF="$WG_CONFS/wg0.conf"
CONTAINER="wireguard"
INTERFACE="wg0"

SERVER_ENDPOINT="home.deloss-s.com:51820"
DNS="192.168.2.10"
ALLOWED_IPS="0.0.0.0/0"
KEEPALIVE=25

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────

container_running() {
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true
}

container_status_line() {
    if container_running; then
        echo -e "  Status: ${GREEN}● running${NC}"
    else
        echo -e "  Status: ${RED}● stopped${NC}"
    fi
}

print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║           WireGuard Manager                   ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    container_status_line
    echo ""
}

print_section() {
    local path=$1
    local title=$2
    print_header
    echo -e "  ${YELLOW}▸ $path${NC}"
    echo -e "  ${BOLD}$title${NC}"
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"
    echo ""
}

pause() {
    echo ""
    read -p "  Press Enter to go back..."
}

ask_input() {
    local prompt=$1
    local varname=$2
    echo -ne "  ${prompt} (or 'q' to cancel): "
    read value
    if [ "$value" = "q" ]; then
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        return 1
    fi
    if [ -z "$value" ]; then
        echo -e "\n  ${RED}Cannot be empty${NC}"
        return 1
    fi
    eval "$varname='$value'"
    return 0
}

ok() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; }
info() { echo -e "  ${CYAN}› $1${NC}"; }
warn() { echo -e "  ${YELLOW}! $1${NC}"; }

server_pubkey() {
    local privkey
    privkey=$(grep '^PrivateKey' "$SERVER_CONF" | awk '{print $3}')
    echo "$privkey" | wg pubkey
}

next_free_ip() {
    local used
    used=$(grep 'AllowedIPs' "$SERVER_CONF" 2>/dev/null | grep -oP '10\.0\.0\.\K\d+' | sort -n)
    local i=2
    while echo "$used" | grep -qx "$i"; do
        ((i++))
    done
    echo "10.0.0.$i"
}

list_clients() {
    local clients=()
    for f in "$CLIENT_CONFS"/*.conf; do
        [ -f "$f" ] && clients+=("$f")
    done
    printf '%s\n' "${clients[@]}"
}

# ─────────────────────────────────────────
# 1. Control
# ─────────────────────────────────────────

wg_start() {
    print_section "1.1" "Control › Start"
    info "Starting container..."
    cd "$WG_DIR" && docker compose up -d
    sleep 1
    if container_running; then
        ok "WireGuard started successfully"
    else
        fail "Failed to start WireGuard"
        echo ""
        docker logs --tail=15 "$CONTAINER"
    fi
    pause
}

wg_stop() {
    print_section "1.2" "Control › Stop"
    echo -ne "  ${RED}Stop WireGuard? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    cd "$WG_DIR" && docker compose down
    sleep 1
    container_running && fail "Failed to stop" || ok "WireGuard stopped"
    pause
}

wg_restart() {
    print_section "1.3" "Control › Restart"
    info "Restarting container..."
    cd "$WG_DIR" && docker compose restart
    sleep 1
    if container_running; then
        ok "WireGuard restarted successfully"
    else
        fail "Restart failed"
        echo ""
        docker logs --tail=15 "$CONTAINER"
    fi
    pause
}

wg_reload() {
    print_section "1.4" "Control › Reload config"
    if ! container_running; then
        fail "Container is not running"
        pause
        return
    fi
    info "Applying config without restart..."
    if docker exec "$CONTAINER" wg syncconf "$INTERFACE" \
        <(docker exec "$CONTAINER" wg-quick strip "$INTERFACE") 2>/dev/null; then
        ok "Config reloaded (no downtime)"
    else
        warn "syncconf failed, trying wg-quick down/up..."
        docker exec "$CONTAINER" wg-quick down "$INTERFACE" 2>/dev/null
        docker exec "$CONTAINER" wg-quick up "$INTERFACE" 2>/dev/null
        ok "Interface restarted"
    fi
    pause
}

menu_control() {
    while true; do
        print_section "1" "Control"
        echo -e "  ${GREEN}1.${NC} Start"
        echo -e "  ${GREEN}2.${NC} Stop"
        echo -e "  ${GREEN}3.${NC} Restart"
        echo -e "  ${GREEN}4.${NC} Reload config (no downtime)"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) wg_start ;;
        2) wg_stop ;;
        3) wg_restart ;;
        4) wg_reload ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 2. Users
# ─────────────────────────────────────────

wg_list_users() {
    print_section "2.1" "Users › List"

    local clients=()
    while IFS= read -r f; do
        [ -n "$f" ] && clients+=("$f")
    done < <(list_clients)

    if [ ${#clients[@]} -eq 0 ]; then
        warn "No clients found"
        pause
        return
    fi

    printf "  %-20s %-16s %s\n" "Name" "IP" "Last handshake"
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"

    for f in "${clients[@]}"; do
        local name ip pubkey handshake_str
        name=$(basename "$f" .conf)
        ip=$(grep '^Address' "$f" | awk '{print $3}' | cut -d/ -f1)

        handshake_str="—"
        if container_running && [ -f "$KEYS_DIR/${name}.pub" ]; then
            pubkey=$(cat "$KEYS_DIR/${name}.pub")
            local ts
            ts=$(docker exec "$CONTAINER" wg show "$INTERFACE" latest-handshakes 2>/dev/null |
                grep "$pubkey" | awk '{print $2}')
            if [ -n "$ts" ] && [ "$ts" != "0" ]; then
                local ago=$(($(date +%s) - ts))
                if [ $ago -lt 60 ]; then
                    handshake_str="${ago}s ago"
                elif [ $ago -lt 3600 ]; then
                    handshake_str="$((ago / 60))m ago"
                else
                    handshake_str="$((ago / 3600))h ago"
                fi
            else
                handshake_str="never"
            fi
        fi

        printf "  ${GREEN}%-20s${NC} %-16s %s\n" "$name" "$ip" "$handshake_str"
    done
    pause
}

wg_add_user() {
    print_section "2.2" "Users › Add user"

    ask_input "Username (letters, digits, _ -)" NAME || {
        pause
        return
    }
    if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        fail "Invalid name: only letters, digits, _ and - allowed"
        pause
        return
    fi
    if [ -f "$CLIENT_CONFS/$NAME.conf" ]; then
        fail "User '$NAME' already exists"
        pause
        return
    fi

    local client_ip
    client_ip=$(next_free_ip)
    info "Assigned IP: $client_ip"

    info "Generating keys..."
    local privkey pubkey srv_pubkey
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    srv_pubkey=$(server_pubkey)

    mkdir -p "$KEYS_DIR"
    echo "$privkey" >"$KEYS_DIR/${NAME}.priv"
    echo "$pubkey" >"$KEYS_DIR/${NAME}.pub"
    chmod 600 "$KEYS_DIR/${NAME}.priv"

    cat >"$CLIENT_CONFS/$NAME.conf" <<EOF
[Interface]
PrivateKey = $privkey
Address = $client_ip/24
DNS = $DNS

[Peer]
PublicKey = $srv_pubkey
Endpoint = $SERVER_ENDPOINT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = $KEEPALIVE
EOF

    printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' \
        "$NAME" "$pubkey" "$client_ip" >>"$SERVER_CONF"

    ok "User '$NAME' created → $client_ip"

    if container_running; then
        docker exec "$CONTAINER" wg set "$INTERFACE" \
            peer "$pubkey" allowed-ips "$client_ip/32" 2>/dev/null &&
            ok "Peer added to live interface" ||
            warn "Could not add to live interface — reload manually"
    fi

    echo ""
    if command -v qrencode &>/dev/null; then
        read -p "  Show QR code? (y/n): " show_qr
        [ "$show_qr" = "y" ] && echo "" && qrencode -t ansiutf8 <"$CLIENT_CONFS/$NAME.conf"
    else
        warn "qrencode not installed — no QR (apt install qrencode)"
        echo ""
        echo -e "  ${BOLD}Client config:${NC}"
        cat "$CLIENT_CONFS/$NAME.conf"
    fi
    pause
}

wg_show_user() {
    print_section "2.3" "Users › Show config / QR"

    local clients=()
    while IFS= read -r f; do
        [ -n "$f" ] && clients+=("$f")
    done < <(list_clients)

    if [ ${#clients[@]} -eq 0 ]; then
        warn "No clients found"
        pause
        return
    fi

    local i=1
    for f in "${clients[@]}"; do
        echo -e "  ${GREEN}$i.${NC} $(basename "$f" .conf)"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select user: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${clients[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local name
    name=$(basename "$target" .conf)

    echo ""
    echo -e "  ${BOLD}=== $name ===${NC}"
    echo ""
    cat "$target"

    if command -v qrencode &>/dev/null; then
        echo ""
        qrencode -t ansiutf8 <"$target"
    else
        warn "qrencode not installed (apt install qrencode)"
    fi
    pause
}

wg_remove_user() {
    print_section "2.4" "Users › Remove user"

    local clients=()
    while IFS= read -r f; do
        [ -n "$f" ] && clients+=("$f")
    done < <(list_clients)

    if [ ${#clients[@]} -eq 0 ]; then
        warn "No clients found"
        pause
        return
    fi

    local i=1
    for f in "${clients[@]}"; do
        echo -e "  ${RED}$i.${NC} $(basename "$f" .conf)"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select user to remove: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${clients[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local name
    name=$(basename "$target" .conf)

    echo ""
    echo -ne "  ${RED}Remove '$name'? This cannot be undone. (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    local pubkey=""
    [ -f "$KEYS_DIR/${name}.pub" ] && pubkey=$(cat "$KEYS_DIR/${name}.pub")

    # Удалить блок из wg0.conf через python3
    python3 - "$SERVER_CONF" "$name" "$pubkey" <<'PYEOF'
import sys, re
conf_path, name, pubkey = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_path) as f:
    content = f.read()
pattern = rf'\n\[Peer\]\n# {re.escape(name)}\nPublicKey = {re.escape(pubkey)}\nAllowedIPs = [^\n]+\n?'
new_content = re.sub(pattern, '', content)
with open(conf_path, 'w') as f:
    f.write(new_content)
PYEOF

    rm -f "$target" "$KEYS_DIR/${name}.priv" "$KEYS_DIR/${name}.pub"

    if [ -n "$pubkey" ] && container_running; then
        docker exec "$CONTAINER" wg set "$INTERFACE" peer "$pubkey" remove 2>/dev/null &&
            ok "Peer removed from live interface" ||
            warn "Could not remove from live interface"
    fi

    ok "User '$name' removed"
    pause
}

menu_users() {
    while true; do
        print_section "2" "Users"
        echo -e "  ${GREEN}1.${NC} List users"
        echo -e "  ${GREEN}2.${NC} Add user"
        echo -e "  ${GREEN}3.${NC} Show config / QR code"
        echo -e "  ${RED}4.${NC} Remove user"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) wg_list_users ;;
        2) wg_add_user ;;
        3) wg_show_user ;;
        4) wg_remove_user ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 3. Status & Logs
# ─────────────────────────────────────────

wg_status() {
    print_section "3.1" "Status › Interface"
    if ! container_running; then
        fail "Container is not running"
        pause
        return
    fi
    echo ""
    docker exec "$CONTAINER" wg show
    pause
}

wg_logs() {
    print_section "3.2" "Status › Logs"
    info "Showing last 50 lines (Ctrl+C to exit)"
    echo ""
    docker logs -f --tail=50 "$CONTAINER"
    pause
}

menu_status() {
    while true; do
        print_section "3" "Status & Logs"
        echo -e "  ${GREEN}1.${NC} Interface status (wg show)"
        echo -e "  ${GREEN}2.${NC} Container logs"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) wg_status ;;
        2) wg_logs ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────

[ $EUID -ne 0 ] && echo -e "${RED}Run as root${NC}" && exit 1
mkdir -p "$WG_CONFS" "$CLIENT_CONFS" "$KEYS_DIR"

while true; do
    print_header
    echo -e "  ${CYAN}1.${NC} Control"
    echo -e "  ${CYAN}2.${NC} Users"
    echo -e "  ${CYAN}3.${NC} Status & Logs"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) menu_control ;;
    2) menu_users ;;
    3) menu_status ;;
    0) echo "" && exit 0 ;;
    *) echo -e "  ${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
