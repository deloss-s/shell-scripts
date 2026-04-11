#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────

UNITS_DIR="/etc/systemd/system"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────

print_header() {
    clear
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║           Systemd Manager                     ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    local services timers
    services=$(get_units service | wc -l)
    timers=$(get_units timer | wc -l)
    echo -e "  Units: ${GREEN}$services services${NC} / ${CYAN}$timers timers${NC}"
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

ok() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; }
info() { echo -e "  ${CYAN}› $1${NC}"; }
warn() { echo -e "  ${YELLOW}! $1${NC}"; }

# Только реальные файлы в /etc/systemd/system (не симлинки, не директории)
get_units() {
    local type="${1:-service}"
    find "$UNITS_DIR" -maxdepth 1 -type f -name "*.${type}" 2>/dev/null | sort
}

# Статус юнита
unit_status_str() {
    local unit=$1
    local active
    active=$(systemctl is-active "$unit" 2>/dev/null)
    local enabled
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null)

    local active_str enabled_str
    case "$active" in
    active) active_str="${GREEN}● active${NC}" ;;
    inactive) active_str="${RED}○ inactive${NC}" ;;
    failed) active_str="${RED}✗ failed${NC}" ;;
    *) active_str="${YELLOW}? $active${NC}" ;;
    esac

    case "$enabled" in
    enabled) enabled_str="${GREEN}enabled${NC}" ;;
    disabled) enabled_str="${RED}disabled${NC}" ;;
    static) enabled_str="${CYAN}static${NC}" ;;
    *) enabled_str="${YELLOW}$enabled${NC}" ;;
    esac

    echo -e "$active_str / $enabled_str"
}

# Найти связанный таймер для сервиса
linked_timer() {
    local service=$1
    local base
    base=$(basename "$service" .service)
    local timer="$UNITS_DIR/${base}.timer"
    [ -f "$timer" ] && echo "$timer"
}

# Выбор юнита из списка
pick_unit() {
    local varname=$1
    local type="${2:-service}"

    local units=()
    while IFS= read -r f; do
        [ -n "$f" ] && units+=("$f")
    done < <(get_units "$type")

    if [ ${#units[@]} -eq 0 ]; then
        warn "No ${type}s found in $UNITS_DIR"
        return 1
    fi

    local i=1
    for u in "${units[@]}"; do
        local name
        name=$(basename "$u")
        local status
        status=$(unit_status_str "$name")
        printf "  ${GREEN}%2d.${NC} %-35s %b\n" "$i" "$name" "$status"
        ((i++))
    done

    echo -e "  ${YELLOW}  0.${NC} Cancel"
    echo ""
    read -p "  Select: " choice
    [ "$choice" = "0" ] && return 1

    local idx=$((choice - 1))
    local target="${units[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        return 1
    }

    eval "$varname='$target'"
    return 0
}

# ─────────────────────────────────────────
# 1. Services
# ─────────────────────────────────────────

svc_list() {
    print_section "1.1" "Services › List"

    local units=()
    while IFS= read -r f; do
        [ -n "$f" ] && units+=("$f")
    done < <(get_units service)

    if [ ${#units[@]} -eq 0 ]; then
        warn "No services found"
        pause
        return
    fi

    printf "  %-35s %-20s %s\n" "Unit" "Status" "Timer"
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"

    for u in "${units[@]}"; do
        local name
        name=$(basename "$u")
        local status
        status=$(unit_status_str "$name")
        local timer_str=""
        local timer
        timer=$(linked_timer "$u")
        [ -n "$timer" ] && timer_str="${CYAN}⏱ $(basename "$timer")${NC}"
        printf "  %-35s %b  %b\n" "$name" "$status" "$timer_str"
    done
    pause
}

svc_control() {
    local action=$1
    local action_label=$2
    local section=$3

    print_section "$section" "Services › $action_label"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo ""
    info "$action_label $name..."
    systemctl "$action" "$name"
    sleep 1
    local status
    status=$(unit_status_str "$name")
    echo -e "  Status: $status"
    pause
}

svc_start() { svc_control start "Start" "1.2"; }
svc_stop() { svc_control stop "Stop" "1.3"; }
svc_restart() { svc_control restart "Restart" "1.4"; }

svc_enable_disable() {
    local action=$1
    local label=$2
    local section=$3

    print_section "$section" "Services › $label"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo ""
    info "$label $name..."
    systemctl "$action" "$name"
    ok "$name ${label,,}d"
    pause
}

svc_enable() { svc_enable_disable enable "Enable" "1.5"; }
svc_disable() { svc_enable_disable disable "Disable" "1.6"; }

svc_status() {
    print_section "1.7" "Services › Status"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo ""
    systemctl status "$name" --no-pager -l
    pause
}

svc_logs() {
    print_section "1.8" "Services › Logs"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    info "Showing last 50 lines (q to exit)"
    echo ""
    journalctl -u "$name" -f -n 50
    pause
}

svc_edit() {
    print_section "1.9" "Services › Edit unit file"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo -e "\n  ${YELLOW}Opening $selected in nvim...${NC}\n"
    nvim "$selected"
    echo ""
    read -p "  Reload systemd daemon and restart $name? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        systemctl daemon-reload
        systemctl restart "$name"
        sleep 1
        local status
        status=$(unit_status_str "$name")
        echo -e "  Status: $status"
    fi
    pause
}

svc_create() {
    print_section "1.10" "Services › Create new service"

    echo -ne "  Service name (without .service): "
    read svc_name
    [ -z "$svc_name" ] && {
        warn "Name cannot be empty"
        pause
        return
    }

    local path="$UNITS_DIR/${svc_name}.service"
    if [ -f "$path" ]; then
        fail "Already exists: $path"
        pause
        return
    fi

    echo -ne "  Description: "
    read svc_desc
    echo -ne "  ExecStart (full command path): "
    read svc_exec
    echo -ne "  Restart policy [no/always/on-failure] (default: on-failure): "
    read svc_restart
    svc_restart="${svc_restart:-on-failure}"
    echo -ne "  WantedBy target (default: multi-user.target): "
    read svc_target
    svc_target="${svc_target:-multi-user.target}"

    cat >"$path" <<EOF
[Unit]
Description=${svc_desc}
After=network.target

[Service]
ExecStart=${svc_exec}
Restart=${svc_restart}
RestartSec=5s

[Install]
WantedBy=${svc_target}
EOF

    ok "Created $path"
    echo ""
    read -p "  Open in nvim to review/edit? (y/n): " edit
    [ "$edit" = "y" ] && nvim "$path"

    echo ""
    read -p "  Enable and start now? (y/n): " start_now
    if [ "$start_now" = "y" ]; then
        systemctl daemon-reload
        systemctl enable "$svc_name.service"
        systemctl start "$svc_name.service"
        sleep 1
        local status
        status=$(unit_status_str "${svc_name}.service")
        echo -e "  Status: $status"
    fi
    pause
}

svc_delete() {
    print_section "1.11" "Services › Delete service"

    local selected=""
    pick_unit selected service || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    local timer
    timer=$(linked_timer "$selected")

    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "  ${RED}•${NC} Stop and disable $name"
    [ -n "$timer" ] && echo -e "  ${RED}•${NC} Stop and disable $(basename "$timer")"
    echo -e "  ${RED}•${NC} Delete $selected"
    [ -n "$timer" ] && echo -e "  ${RED}•${NC} Delete $timer"
    echo ""
    echo -ne "  ${RED}Type 'delete' to confirm:${NC} "
    read confirm
    [ "$confirm" != "delete" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    systemctl stop "$name" 2>/dev/null
    systemctl disable "$name" 2>/dev/null
    rm -f "$selected"
    ok "$name stopped, disabled and deleted"

    if [ -n "$timer" ]; then
        local tname
        tname=$(basename "$timer")
        systemctl stop "$tname" 2>/dev/null
        systemctl disable "$tname" 2>/dev/null
        rm -f "$timer"
        ok "$tname stopped, disabled and deleted"
    fi

    systemctl daemon-reload
    ok "Daemon reloaded"
    pause
}

menu_services() {
    while true; do
        print_section "1" "Services"
        echo -e "  ${GREEN}1.${NC}  List services"
        echo -e "  ${GREEN}2.${NC}  Start"
        echo -e "  ${GREEN}3.${NC}  Stop"
        echo -e "  ${GREEN}4.${NC}  Restart"
        echo -e "  ${GREEN}5.${NC}  Enable"
        echo -e "  ${GREEN}6.${NC}  Disable"
        echo -e "  ${GREEN}7.${NC}  Status"
        echo -e "  ${GREEN}8.${NC}  Logs"
        echo -e "  ${GREEN}9.${NC}  Edit unit file"
        echo -e "  ${GREEN}10.${NC} Create new service"
        echo -e "  ${RED}11.${NC} Delete service"
        echo -e "  ${YELLOW}0.${NC}  Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) svc_list ;;
        2) svc_start ;;
        3) svc_stop ;;
        4) svc_restart ;;
        5) svc_enable ;;
        6) svc_disable ;;
        7) svc_status ;;
        8) svc_logs ;;
        9) svc_edit ;;
        10) svc_create ;;
        11) svc_delete ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 2. Timers
# ─────────────────────────────────────────

tmr_list() {
    print_section "2.1" "Timers › List"

    local units=()
    while IFS= read -r f; do
        [ -n "$f" ] && units+=("$f")
    done < <(get_units timer)

    if [ ${#units[@]} -eq 0 ]; then
        warn "No timers found"
        pause
        return
    fi

    printf "  %-35s %-20s %s\n" "Unit" "Status" "Next trigger"
    echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"

    for u in "${units[@]}"; do
        local name
        name=$(basename "$u")
        local status
        status=$(unit_status_str "$name")
        local next
        next=$(systemctl show "$name" --property=NextElapseUSecRealtime 2>/dev/null |
            cut -d= -f2 | xargs -I{} date -d @{} '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
        [ -z "$next" ] || [ "$next" = " " ] && next="—"
        printf "  %-35s %b  %s\n" "$name" "$status" "$next"
    done
    pause
}

tmr_control() {
    local action=$1
    local label=$2
    local section=$3

    print_section "$section" "Timers › $label"

    local selected=""
    pick_unit selected timer || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo ""
    info "$label $name..."
    systemctl "$action" "$name"
    sleep 1
    local status
    status=$(unit_status_str "$name")
    echo -e "  Status: $status"
    pause
}

tmr_start() { tmr_control start "Start" "2.2"; }
tmr_stop() { tmr_control stop "Stop" "2.3"; }
tmr_enable() { tmr_control enable "Enable" "2.4"; }
tmr_disable() { tmr_control disable "Disable" "2.5"; }

tmr_status() {
    print_section "2.6" "Timers › Status"

    local selected=""
    pick_unit selected timer || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo ""
    systemctl status "$name" --no-pager -l
    pause
}

tmr_logs() {
    print_section "2.7" "Timers › Logs"

    local selected=""
    pick_unit selected timer || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    # Логи самого таймера + связанного сервиса
    local svc_name="${name%.timer}.service"
    info "Showing last 50 lines (q to exit)"
    echo ""
    journalctl -u "$name" -u "$svc_name" -f -n 50
    pause
}

tmr_edit() {
    print_section "2.8" "Timers › Edit unit file"

    local selected=""
    pick_unit selected timer || {
        pause
        return
    }

    local name
    name=$(basename "$selected")
    echo -e "\n  ${YELLOW}Opening $selected in nvim...${NC}\n"
    nvim "$selected"
    echo ""
    read -p "  Reload systemd daemon and restart $name? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        systemctl daemon-reload
        systemctl restart "$name"
        sleep 1
        local status
        status=$(unit_status_str "$name")
        echo -e "  Status: $status"
    fi
    pause
}

tmr_create() {
    print_section "2.9" "Timers › Create new timer"

    echo -ne "  Timer name (without .timer, must match a .service): "
    read tmr_name
    [ -z "$tmr_name" ] && {
        warn "Name cannot be empty"
        pause
        return
    }

    local path="$UNITS_DIR/${tmr_name}.timer"
    if [ -f "$path" ]; then
        fail "Already exists: $path"
        pause
        return
    fi

    local svc_path="$UNITS_DIR/${tmr_name}.service"
    [ ! -f "$svc_path" ] && warn "Note: ${tmr_name}.service not found — create it too"

    echo -ne "  Description: "
    read tmr_desc
    echo -e "  OnCalendar examples: daily / weekly / hourly / *-*-* 03:00:00"
    echo -ne "  OnCalendar: "
    read tmr_calendar
    tmr_calendar="${tmr_calendar:-daily}"

    cat >"$path" <<EOF
[Unit]
Description=${tmr_desc}

[Timer]
OnCalendar=${tmr_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    ok "Created $path"
    echo ""
    read -p "  Open in nvim to review/edit? (y/n): " edit
    [ "$edit" = "y" ] && nvim "$path"

    echo ""
    read -p "  Enable and start now? (y/n): " start_now
    if [ "$start_now" = "y" ]; then
        systemctl daemon-reload
        systemctl enable "$tmr_name.timer"
        systemctl start "$tmr_name.timer"
        sleep 1
        local status
        status=$(unit_status_str "${tmr_name}.timer")
        echo -e "  Status: $status"
    fi
    pause
}

tmr_delete() {
    print_section "2.10" "Timers › Delete timer"

    local selected=""
    pick_unit selected timer || {
        pause
        return
    }

    local name
    name=$(basename "$selected")

    echo ""
    echo -ne "  ${RED}Stop, disable and delete $name? Type 'delete' to confirm:${NC} "
    read confirm
    [ "$confirm" != "delete" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    systemctl stop "$name" 2>/dev/null
    systemctl disable "$name" 2>/dev/null
    rm -f "$selected"
    systemctl daemon-reload
    ok "$name deleted and daemon reloaded"
    pause
}

menu_timers() {
    while true; do
        print_section "2" "Timers"
        echo -e "  ${GREEN}1.${NC}  List timers"
        echo -e "  ${GREEN}2.${NC}  Start"
        echo -e "  ${GREEN}3.${NC}  Stop"
        echo -e "  ${GREEN}4.${NC}  Enable"
        echo -e "  ${GREEN}5.${NC}  Disable"
        echo -e "  ${GREEN}6.${NC}  Status"
        echo -e "  ${GREEN}7.${NC}  Logs"
        echo -e "  ${GREEN}8.${NC}  Edit unit file"
        echo -e "  ${GREEN}9.${NC}  Create new timer"
        echo -e "  ${RED}10.${NC} Delete timer"
        echo -e "  ${YELLOW}0.${NC}  Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) tmr_list ;;
        2) tmr_start ;;
        3) tmr_stop ;;
        4) tmr_enable ;;
        5) tmr_disable ;;
        6) tmr_status ;;
        7) tmr_logs ;;
        8) tmr_edit ;;
        9) tmr_create ;;
        10) tmr_delete ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# Main Menu
# ─────────────────────────────────────────

[ $EUID -ne 0 ] && echo -e "${RED}Run as root${NC}" && exit 1

while true; do
    print_header
    echo -e "  ${CYAN}1.${NC} Services"
    echo -e "  ${CYAN}2.${NC} Timers"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) menu_services ;;
    2) menu_timers ;;
    0) echo "" && exit 0 ;;
    *) echo -e "  ${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
