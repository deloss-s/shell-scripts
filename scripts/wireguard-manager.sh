#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────

WG_BASE="/etc/wireguard"
CLIENT_CONFS="$WG_BASE/client_confs"
KEYS_DIR="$WG_BASE/keys"
SERVER_CONF="$WG_BASE/wg0.conf"
INTERFACE="wg0"

SERVER_ENDPOINT="home.deloss-s.com:51820"
SERVER_SUBNET="10.0.0.0/24"
SERVER_IP="10.0.0.1"
DNS="192.168.2.10"
ALLOWED_IPS="0.0.0.0/0"
KEEPALIVE=25
WG_PORT=51820

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────

iface_running() {
    wg show "$INTERFACE" &>/dev/null
}

iface_status_line() {
    if iface_running; then
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
    iface_status_line
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
    grep '^PrivateKey' "$SERVER_CONF" | awk '{print $3}' | wg pubkey
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
    for f in "$CLIENT_CONFS"/*.conf; do
        [ -f "$f" ] && echo "$f"
    done
}

show_qr() {
    local conf_path=$1
    qrencode -t ansiutf8 -s 1 <"$conf_path"
}

# ─────────────────────────────────────────
# 1. Control
# ─────────────────────────────────────────

wg_start() {
    print_section "1.1" "Control › Start"
    info "Starting $INTERFACE..."
    systemctl start "wg-quick@$INTERFACE"
    sleep 1
    if iface_running; then
        ok "WireGuard started successfully"
    else
        fail "Failed to start WireGuard"
        echo ""
        journalctl -u "wg-quick@$INTERFACE" -n 15 --no-pager
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
    systemctl stop "wg-quick@$INTERFACE"
    sleep 1
    iface_running && fail "Failed to stop" || ok "WireGuard stopped"
    pause
}

wg_restart() {
    print_section "1.3" "Control › Restart"
    info "Restarting $INTERFACE..."
    systemctl restart "wg-quick@$INTERFACE"
    sleep 1
    if iface_running; then
        ok "WireGuard restarted successfully"
    else
        fail "Restart failed"
        echo ""
        journalctl -u "wg-quick@$INTERFACE" -n 15 --no-pager
    fi
    pause
}

wg_reload() {
    print_section "1.4" "Control › Reload config"
    if ! iface_running; then
        fail "Interface is not running"
        pause
        return
    fi
    info "Applying config without downtime..."
    if wg syncconf "$INTERFACE" <(wg-quick strip "$INTERFACE") 2>/dev/null; then
        ok "Config reloaded (no downtime)"
    else
        warn "syncconf failed, restarting..."
        systemctl restart "wg-quick@$INTERFACE"
        sleep 1
        iface_running && ok "Restarted successfully" || fail "Restart failed"
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

        if iface_running && [ -f "$KEYS_DIR/${name}.pub" ]; then
            pubkey=$(cat "$KEYS_DIR/${name}.pub")
            local ts
            ts=$(wg show "$INTERFACE" latest-handshakes 2>/dev/null |
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

    [ ! -f "$SERVER_CONF" ] && {
        fail "Server config not found — run Autodeploy first"
        pause
        return
    }

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

    if iface_running; then
        wg set "$INTERFACE" peer "$pubkey" allowed-ips "$client_ip/32" 2>/dev/null &&
            ok "Peer added to live interface" ||
            warn "Could not add to live interface — reload manually"
    fi

    echo ""
    if command -v qrencode &>/dev/null; then
        read -p "  Show QR code? (y/n): " show_qr_ans
        if [ "$show_qr_ans" = "y" ]; then
            echo ""
            show_qr "$CLIENT_CONFS/$NAME.conf"
        fi
    else
        warn "qrencode not installed (apt install qrencode)"
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
        show_qr "$target"
    else
        warn "qrencode not installed (apt install qrencode)"
    fi
    pause
}

wg_monitor() {
    if ! iface_running; then
        print_section "2.3" "Users › Monitor connections"
        fail "Interface is not running"
        pause
        return
    fi

    declare -A pubkey_to_name
    for pubfile in "$KEYS_DIR"/*.pub; do
        [ -f "$pubfile" ] || continue
        local bname
        bname=$(basename "$pubfile" .pub)
        [[ "$bname" == "server" ]] && continue
        local pk
        pk=$(cat "$pubfile")
        pubkey_to_name["$pk"]="$bname"
    done

    declare -A prev_state
    local events=()
    local _monitor_exit=0

    # Перехватываем Ctrl+C локально — просто выходим из монитора
    trap '_monitor_exit=1' INT

    while [ $_monitor_exit -eq 0 ]; do
        clear
        echo -e "${CYAN}"
        echo "  ╔═══════════════════════════════════════════════╗"
        echo "  ║         WireGuard — Live Monitor              ║"
        echo "  ╚═══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${YELLOW}Updated: $(date '+%H:%M:%S')${NC}   Press q + Enter to go back"
        echo ""
        echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"
        printf "  %-20s %-16s %-14s %-20s %s\n" "User" "IP" "Status" "Last handshake" "TX/RX"
        echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"

        local now
        now=$(date +%s)

        fmt_bytes() {
            local b=$1
            if [ "$b" -ge 1073741824 ]; then
                printf "%.1fG" "$(echo "scale=1; $b/1073741824" | bc)"
            elif [ "$b" -ge 1048576 ]; then
                printf "%.1fM" "$(echo "scale=1; $b/1048576" | bc)"
            elif [ "$b" -ge 1024 ]; then
                printf "%.1fK" "$(echo "scale=1; $b/1024" | bc)"
            else printf "%dB" "$b"; fi
        }

        while IFS=$'\t' read -r pubkey _pre _ep allowed_ips handshake rx tx _ka; do
            local uname="${pubkey_to_name[$pubkey]:-unknown}"
            local ip
            ip=$(echo "$allowed_ips" | cut -d/ -f1)

            local ago status_str status_color cur_state
            if [[ "$handshake" =~ ^[0-9]+$ ]] && [ "$handshake" -gt 0 ]; then
                ago=$((now - handshake))
            else
                ago=999999
            fi

            if [ "$ago" -lt 180 ]; then
                status_str="● online"
                status_color="$GREEN"
                cur_state="online"
            else
                status_str="○ offline"
                status_color="$RED"
                cur_state="offline"
            fi

            if [[ -n "${prev_state[$pubkey]:-}" && "${prev_state[$pubkey]}" != "$cur_state" ]]; then
                local ts
                ts=$(date '+%H:%M:%S')
                if [ "$cur_state" = "online" ]; then
                    events+=("${GREEN}[${ts}] ${uname} connected${NC}")
                else
                    events+=("${RED}[${ts}] ${uname} disconnected${NC}")
                fi
            fi
            prev_state["$pubkey"]="$cur_state"

            local hs_str
            if [ "$ago" -eq 999999 ]; then
                hs_str="never"
            elif [ "$ago" -lt 60 ]; then
                hs_str="${ago}s ago"
            elif [ "$ago" -lt 3600 ]; then
                hs_str="$((ago / 60))m ago"
            else
                hs_str="$((ago / 3600))h $((ago % 3600 / 60))m ago"
            fi

            local tx_fmt rx_fmt
            tx_fmt=$(fmt_bytes "$tx")
            rx_fmt=$(fmt_bytes "$rx")

            printf "  ${status_color}%-20s${NC} %-16s ${status_color}%-14s${NC} %-20s %s/%s\n" \
                "$uname" "$ip" "$status_str" "$hs_str" "$tx_fmt" "$rx_fmt"

        done < <(wg show "$INTERFACE" dump 2>/dev/null | tail -n +2)

        echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"

        if [ ${#events[@]} -gt 0 ]; then
            echo ""
            echo -e "  ${BOLD}Events:${NC}"
            local start=$((${#events[@]} - 5))
            [ $start -lt 0 ] && start=0
            for ((i = start; i < ${#events[@]}; i++)); do
                echo -e "  ${events[$i]}"
            done
        fi

        # Неблокирующий read: ждём 2 секунды, если нажали q — выходим
        if read -r -t 2 _key 2>/dev/null; then
            [[ "$_key" == "q" || "$_key" == "Q" ]] && _monitor_exit=1
        fi
    done

    # Восстанавливаем стандартный обработчик INT
    trap - INT
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

    if [ -n "$pubkey" ] && iface_running; then
        wg set "$INTERFACE" peer "$pubkey" remove 2>/dev/null &&
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
        echo -e "  ${GREEN}2.${NC} Show config / QR code"
        echo -e "  ${GREEN}3.${NC} Monitor connections"
        echo -e "  ${GREEN}4.${NC} Add user"
        echo -e "  ${RED}5.${NC} Remove user"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) wg_list_users ;;
        2) wg_show_user ;;
        3) wg_monitor ;;
        4) wg_add_user ;;
        5) wg_remove_user ;;
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
    if ! iface_running; then
        fail "Interface is not running"
        pause
        return
    fi
    echo ""
    wg show
    pause
}

wg_logs() {
    print_section "3.2" "Status › Logs"
    info "Showing last 50 lines (Ctrl+C to exit)"
    echo ""
    journalctl -u "wg-quick@$INTERFACE" -f -n 50
    pause
}

menu_status() {
    while true; do
        print_section "3" "Status & Logs"
        echo -e "  ${GREEN}1.${NC} Interface status (wg show)"
        echo -e "  ${GREEN}2.${NC} Logs"
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
# 4. Autodeploy
# ─────────────────────────────────────────

wg_autodeploy() {
    print_section "4" "Autodeploy"

    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "  ${RED}•${NC} Stop WireGuard if running"
    echo -e "  ${RED}•${NC} Wipe $KEYS_DIR/ and $CLIENT_CONFS/"
    echo -e "  ${RED}•${NC} Generate new server keys"
    echo -e "  ${RED}•${NC} Write fresh $SERVER_CONF"
    echo -e "  ${RED}•${NC} Enable and start wg-quick@$INTERFACE"
    echo -e "  ${YELLOW}•${NC} All existing users will be lost"
    echo ""
    echo -e "  ${RED}${BOLD}This cannot be undone.${NC}"
    echo ""
    echo -ne "  ${RED}Type 'deploy' to confirm:${NC} "
    read confirm
    if [ "$confirm" != "deploy" ]; then
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    fi

    echo ""

    # 1. Остановить интерфейс
    if iface_running; then
        info "Stopping WireGuard..."
        systemctl stop "wg-quick@$INTERFACE" 2>/dev/null || wg-quick down "$INTERFACE" 2>/dev/null
        ok "Stopped"
    fi

    # 2. Проверить что wireguard установлен
    if ! command -v wg &>/dev/null; then
        info "Installing wireguard-tools..."
        apt-get install -y wireguard-tools >/dev/null 2>&1 &&
            ok "wireguard-tools installed" ||
            {
                fail "Failed to install wireguard-tools"
                pause
                return
            }
    fi

    # 3. Создать директории
    info "Creating directories..."
    mkdir -p "$WG_BASE" "$CLIENT_CONFS" "$KEYS_DIR"
    chmod 700 "$WG_BASE" "$KEYS_DIR"
    ok "Directories ready"

    # 4. Очистить старые данные
    info "Wiping old keys and client configs..."
    rm -f "$KEYS_DIR"/*.priv "$KEYS_DIR"/*.pub
    rm -f "$CLIENT_CONFS"/*.conf
    ok "Wiped"

    # 5. Генерация серверных ключей
    info "Generating server keys..."
    local srv_privkey srv_pubkey
    srv_privkey=$(wg genkey)
    srv_pubkey=$(echo "$srv_privkey" | wg pubkey)
    echo "$srv_privkey" >"$KEYS_DIR/server.priv"
    echo "$srv_pubkey" >"$KEYS_DIR/server.pub"
    chmod 600 "$KEYS_DIR/server.priv"
    ok "Server keys generated"

    # 6. Определить внешний интерфейс для MASQUERADE
    local ext_iface
    ext_iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    ext_iface="${ext_iface:-eth0}"
    info "Detected external interface: $ext_iface"

    # 7. Записать wg0.conf
    info "Writing $SERVER_CONF..."
    cat >"$SERVER_CONF" <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $srv_privkey

PostUp   = iptables -t nat -A POSTROUTING -s $SERVER_SUBNET -o $ext_iface -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s $SERVER_SUBNET -o $ext_iface -j MASQUERADE
EOF
    chmod 600 "$SERVER_CONF"
    ok "Server config written"

    # 8. Включить IP forwarding
    info "Enabling IP forwarding..."
    if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv4.ip_forward=1' >>/etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    ok "IP forwarding enabled"

    # 9. Включить и запустить systemd-сервис
    info "Enabling wg-quick@$INTERFACE..."
    systemctl enable "wg-quick@$INTERFACE" 2>/dev/null
    systemctl start "wg-quick@$INTERFACE"
    sleep 1

    if iface_running; then
        ok "WireGuard is running"
    else
        fail "WireGuard failed to start"
        echo ""
        journalctl -u "wg-quick@$INTERFACE" -n 20 --no-pager
        pause
        return
    fi

    echo ""
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Deploy complete${NC}"
    echo ""
    echo -e "  Server public key:"
    echo -e "  ${GREEN}$srv_pubkey${NC}"
    echo ""
    echo -e "  Endpoint:  ${BOLD}$SERVER_ENDPOINT${NC}"
    echo -e "  Subnet:    ${BOLD}$SERVER_SUBNET${NC}"
    echo -e "  Interface: ${BOLD}$ext_iface${NC}"
    echo ""
    warn "Add users via menu → 2. Users → 2. Add user"
    pause
}

# ─────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────

[ $EUID -ne 0 ] && echo -e "${RED}Run as root${NC}" && exit 1

while true; do
    print_header
    echo -e "  ${CYAN}1.${NC} Control"
    echo -e "  ${CYAN}2.${NC} Users"
    echo -e "  ${CYAN}3.${NC} Status & Logs"
    echo -e "  ${RED}4.${NC} Autodeploy"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) menu_control ;;
    2) menu_users ;;
    3) menu_status ;;
    4) wg_autodeploy ;;
    0) echo "" && exit 0 ;;
    *) echo -e "  ${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
