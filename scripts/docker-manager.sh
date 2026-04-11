#!/bin/bash

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────

DOCKER_ROOT="/root/linux-all/selfhosted/docker"
JUNK_DIR="$DOCKER_ROOT/junk"

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
    echo "  ║           Docker Manager                      ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    local running
    running=$(docker ps -q 2>/dev/null | wc -l)
    local total
    total=$(docker ps -aq 2>/dev/null | wc -l)
    echo -e "  Containers: ${GREEN}$running running${NC} / $total total"
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

# Список директорий с docker-compose.yml, исключая junk
get_services() {
    find "$DOCKER_ROOT" -mindepth 1 -maxdepth 1 -type d \
        ! -path "$JUNK_DIR" \
        ! -path "$JUNK_DIR/*" | sort | while read -r dir; do
        [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ] && echo "$dir"
    done
}

# Получить файл compose для директории
get_compose_file() {
    local dir=$1
    if [ -f "$dir/docker-compose.yml" ]; then
        echo "$dir/docker-compose.yml"
    elif [ -f "$dir/docker-compose.yaml" ]; then
        echo "$dir/docker-compose.yaml"
    fi
}

# Выбор сервиса из списка, результат в переменную
pick_service() {
    local varname=$1
    local services=()
    while IFS= read -r d; do
        [ -n "$d" ] && services+=("$d")
    done < <(get_services)

    if [ ${#services[@]} -eq 0 ]; then
        warn "No services found in $DOCKER_ROOT"
        return 1
    fi

    local i=1
    for d in "${services[@]}"; do
        local name
        name=$(basename "$d")
        local compose
        compose=$(get_compose_file "$d")
        local compose_name
        compose_name=$(basename "$compose" 2>/dev/null)

        # Статус контейнеров сервиса
        local status_str=""
        local running_count
        running_count=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)
        if [ "$running_count" -gt 0 ]; then
            status_str=" ${GREEN}● up ($running_count)${NC}"
        else
            status_str=" ${RED}○ down${NC}"
        fi

        printf "  ${GREEN}%2d.${NC} %-25s%b\n" "$i" "$name" "$status_str"
        ((i++))
    done

    echo -e "  ${YELLOW}  0.${NC} Cancel"
    echo ""
    read -p "  Select service: " choice
    [ "$choice" = "0" ] && return 1

    local idx=$((choice - 1))
    local target="${services[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        return 1
    }

    eval "$varname='$target'"
    return 0
}

# ─────────────────────────────────────────
# 1. Images
# ─────────────────────────────────────────

images_list() {
    print_section "3.1" "Images › List"
    echo ""
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" |
        awk 'NR==1 {printf "  %-40s %-15s %-10s %s\n", $1, $2, $3, $4} NR>1 {printf "  %-40s %-15s %-10s %s\n", $1, $2, $3, $4}'
    pause
}

images_delete() {
    print_section "3.2" "Images › Delete image"

    local images=()
    while IFS= read -r line; do
        [ -n "$line" ] && images+=("$line")
    done < <(docker images --format "{{.Repository}}:{{.Tag}}  ({{.Size}}, {{.CreatedSince}})" 2>/dev/null)

    if [ ${#images[@]} -eq 0 ]; then
        warn "No images found"
        pause
        return
    fi

    local i=1
    for img in "${images[@]}"; do
        echo -e "  ${RED}$i.${NC} $img"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select image to delete: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local selected="${images[$idx]}"
    [ -z "$selected" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local img_name
    img_name=$(echo "$selected" | awk '{print $1}')

    echo ""
    echo -e "  ${YELLOW}Image:${NC} $img_name"
    echo -ne "  ${RED}Delete? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    echo ""
    read -p "  Force remove (even if used by stopped containers)? (y/n): " force
    if [ "$force" = "y" ]; then
        docker rmi -f "$img_name" && ok "Image deleted" || fail "Failed to delete"
    else
        docker rmi "$img_name" && ok "Image deleted" || fail "Failed to delete (try force)"
    fi
    pause
}

menu_images() {
    while true; do
        print_section "3" "Images"
        echo -e "  ${GREEN}1.${NC} List images"
        echo -e "  ${RED}2.${NC} Delete image"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) images_list ;;
        2) images_delete ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 2. Containers & Compose
# ─────────────────────────────────────────

compose_list_files() {
    print_section "1.1" "Containers › List services (docker-compose.yml)"
    echo -e "  ${YELLOW}$DOCKER_ROOT${NC}  (junk excluded)\n"

    local found=0
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        local name
        name=$(basename "$dir")
        local compose
        compose=$(get_compose_file "$dir")
        local compose_name
        compose_name=$(basename "$compose")

        local running
        running=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)
        local status_str
        if [ "$running" -gt 0 ]; then
            status_str="${GREEN}● up ($running)${NC}"
        else
            status_str="${RED}○ down${NC}"
        fi

        printf "  ${CYAN}%-25s${NC} %-25s %b\n" "$name" "docker-compose.yml" "$status_str"
        found=1
    done < <(get_services)

    [ $found -eq 0 ] && warn "No services found"
    pause
}

compose_list_running() {
    print_section "1.2" "Containers › Running containers"
    echo ""
    local count
    count=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | wc -l)
    if [ "$count" -le 1 ]; then
        warn "No running containers"
    else
        docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" |
            awk 'NR==1 {printf "  %-30s %-35s %-20s %s\n", $1, $2, $3, $4}
                   NR>1  {printf "  %-30s %-35s %-20s %s\n", $1, $2, $3, $4}'
    fi
    pause
}

# ── Service submenu ──

service_up() {
    local dir=$1
    local name
    name=$(basename "$dir")
    local compose
    compose=$(get_compose_file "$dir")
    print_section "1.1.1" "Service › $name › Up (docker-compose.yml)"
    info "Starting $name..."
    cd "$dir" && docker compose up -d
    echo ""
    docker compose ps
    pause
}

service_down() {
    local dir=$1
    local name
    name=$(basename "$dir")
    local compose
    compose=$(get_compose_file "$dir")
    print_section "1.1.2" "Service › $name › Down (docker-compose.yml)"
    echo -ne "  ${RED}Stop $name? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    cd "$dir" && docker compose down
    ok "$name stopped"
    pause
}

service_restart() {
    local dir=$1
    local name
    name=$(basename "$dir")
    print_section "1.1.3" "Service › $name › Restart (docker-compose.yml)"
    info "Restarting $name..."
    cd "$dir" && docker compose restart
    echo ""
    docker compose ps
    pause
}

service_logs() {
    local dir=$1
    local name
    name=$(basename "$dir")
    print_section "1.1.4" "Service › $name › Logs (docker-compose.yml)"
    info "Showing last 50 lines (q to exit)"
    echo ""
    cd "$dir" && docker compose logs --tail=50 --follow
    pause
}

service_status() {
    local dir=$1
    local name
    name=$(basename "$dir")
    print_section "1.1.5" "Service › $name › Status (docker-compose.yml)"
    echo ""
    cd "$dir" && docker compose ps
    pause
}

service_pull() {
    local dir=$1
    local name
    name=$(basename "$dir")
    print_section "1.1.6" "Service › $name › Pull & recreate (docker-compose.yml)"
    echo -ne "  Pull new images and recreate containers for $name? (y/n): "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }
    info "Pulling images..."
    cd "$dir" && docker compose pull
    echo ""
    info "Recreating containers..."
    docker compose up -d --force-recreate
    ok "Done"
    pause
}

service_edit() {
    local root_dir=$1
    local name
    name=$(basename "$root_dir")
    local current_dir="$root_dir"

    while true; do
        print_section "1.1.7" "Service › $name › Edit configuration"
        echo -e "  ${YELLOW}$current_dir${NC}\n"

        local entries=()
        local entry_types=()

        local show_back=0
        [ "$current_dir" != "$root_dir" ] && show_back=1

        if [ $show_back -eq 1 ]; then
            echo -e "  ${CYAN}0.${NC} .. (back)"
        else
            echo -e "  ${YELLOW}0.${NC} Cancel"
        fi

        local i=1
        # Директории
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            echo -e "  ${CYAN}$i.${NC} $(basename "$d")/"
            entries+=("$d")
            entry_types+=("dir")
            ((i++))
        done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -type d | sort)

        # Файлы
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            echo -e "  ${GREEN}$i.${NC} $(basename "$f")"
            entries+=("$f")
            entry_types+=("file")
            ((i++))
        done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -type f | sort)

        echo ""
        echo -e "  ${CYAN}n.${NC} New file"
        echo -e "  ${RED}d.${NC} Delete file"
        echo ""
        read -p "  Select (number / n / d / 0): " choice

        # Назад / отмена
        if [ "$choice" = "0" ]; then
            if [ $show_back -eq 1 ]; then
                current_dir=$(dirname "$current_dir")
            else
                return
            fi
            continue
        fi

        # Создать новый файл
        if [ "$choice" = "n" ] || [ "$choice" = "N" ]; then
            echo -ne "\n  File name: "
            read new_fname
            [ -z "$new_fname" ] && {
                warn "Name cannot be empty"
                sleep 1
                continue
            }
            local new_path="$current_dir/$new_fname"
            if [ -e "$new_path" ]; then
                warn "Already exists: $new_fname"
                sleep 1
                continue
            fi
            touch "$new_path"
            ok "Created $new_fname"
            sleep 0.5
            nvim "$new_path"
            continue
        fi

        # Удалить файл
        if [ "$choice" = "d" ] || [ "$choice" = "D" ]; then
            if [ ${#entries[@]} -eq 0 ]; then
                warn "Nothing to delete"
                sleep 1
                continue
            fi
            echo ""
            echo -e "  ${RED}Select file to delete:${NC}\n"
            local j=1
            local del_entries=()
            for e in "${entries[@]}"; do
                local etype="${entry_types[$((j - 1))]}"
                [ "$etype" = "file" ] || {
                    ((j++))
                    continue
                }
                echo -e "  ${RED}$j.${NC} $(basename "$e")"
                del_entries+=("$e")
                ((j++))
            done
            [ ${#del_entries[@]} -eq 0 ] && {
                warn "No files to delete (directories not deletable here)"
                sleep 1
                continue
            }
            echo -e "  ${YELLOW}0.${NC} Cancel"
            echo ""
            read -p "  Select: " del_choice
            [ "$del_choice" = "0" ] && continue
            local del_idx=$((del_choice - 1))
            local del_target="${del_entries[$del_idx]:-}"
            [ -z "$del_target" ] && {
                echo -e "\n  ${RED}Invalid${NC}"
                sleep 1
                continue
            }
            echo ""
            echo -ne "  ${RED}Delete $(basename "$del_target")? (y/n):${NC} "
            read del_confirm
            [ "$del_confirm" != "y" ] && continue
            rm -f "$del_target" && ok "Deleted $(basename "$del_target")" || fail "Failed to delete"
            sleep 1
            continue
        fi

        # Выбор по номеру
        local idx=$((choice - 1))
        local target="${entries[$idx]:-}"
        local ttype="${entry_types[$idx]:-}"
        [ -z "$target" ] && {
            echo -e "\n  ${RED}Invalid${NC}"
            sleep 1
            continue
        }

        if [ "$ttype" = "dir" ]; then
            current_dir="$target"
        else
            echo -e "\n  ${YELLOW}Opening $(basename "$target") in nvim...${NC}\n"
            nvim "$target"
            echo ""
            local compose
            compose=$(get_compose_file "$root_dir")
            if [ -n "$compose" ]; then
                read -p "  Restart service to apply changes? (y/n): " restart
                if [ "$restart" = "y" ]; then
                    cd "$root_dir" && docker compose restart
                    ok "Restarted"
                fi
            fi
        fi
    done
}

compose_choose_service() {
    local selected_dir=""

    while true; do
        print_section "1.1" "Containers › Choose service"
        pick_service selected_dir || return

        # Остаёмся в цикле выбора сервиса — menu_service возвращает сюда
        while true; do
            local name
            name=$(basename "$selected_dir")
            local compose
            compose=$(get_compose_file "$selected_dir")
            local running
            running=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)

            print_section "1.1" "Service › $name"
            if [ "$running" -gt 0 ]; then
                echo -e "  Status: ${GREEN}● up ($running containers)${NC}"
            else
                echo -e "  Status: ${RED}○ down${NC}"
            fi
            echo ""
            echo -e "  ${GREEN}1.${NC} Up (docker-compose.yml)"
            echo -e "  ${GREEN}2.${NC} Down (docker-compose.yml)"
            echo -e "  ${GREEN}3.${NC} Restart (docker-compose.yml)"
            echo -e "  ${GREEN}4.${NC} Logs"
            echo -e "  ${GREEN}5.${NC} Status"
            echo -e "  ${GREEN}6.${NC} Pull & recreate (docker-compose.yml)"
            echo -e "  ${GREEN}7.${NC} Edit configuration"
            echo -e "  ${YELLOW}0.${NC} Back to service list"
            echo ""
            read -p "  Choice: " c
            case $c in
            1) service_up "$selected_dir" ;;
            2) service_down "$selected_dir" ;;
            3) service_restart "$selected_dir" ;;
            4) service_logs "$selected_dir" ;;
            5) service_status "$selected_dir" ;;
            6) service_pull "$selected_dir" ;;
            7) service_edit "$selected_dir" ;;
            0) break ;;
            *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
            esac
        done
        # После break — возвращаемся к pick_service
    done
}

all_up() {
    print_section "1.3" "Containers › Up all"
    info "Starting all services via docker-compose.yml..."
    echo ""
    local failed=0
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        local name
        name=$(basename "$dir")
        local compose
        compose=$(get_compose_file "$dir")
        echo -ne "  ${CYAN}$name${NC}... "
        if cd "$dir" && docker compose up -d 2>/dev/null; then
            echo -e "${GREEN}up${NC}"
        else
            echo -e "${RED}failed${NC}"
            ((failed++))
        fi
    done < <(get_services)
    echo ""
    [ $failed -gt 0 ] && fail "$failed service(s) failed to start" || ok "All services started"
    pause
}

all_down() {
    print_section "1.4" "Containers › Down all"
    echo -ne "  ${RED}Stop ALL services? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "
  Cancelled."
        pause
        return
    }
    echo ""
    local failed=0
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        local name
        name=$(basename "$dir")
        echo -ne "  ${CYAN}$name${NC}... "
        if cd "$dir" && docker compose down 2>/dev/null; then
            echo -e "${GREEN}down${NC}"
        else
            echo -e "${RED}failed${NC}"
            ((failed++))
        fi
    done < <(get_services)
    echo ""
    [ $failed -gt 0 ] && fail "$failed service(s) failed to stop" || ok "All services stopped"
    pause
}

compose_create() {
    print_section "1.4" "Containers › Create new service (docker-compose.yml)"

    echo -ne "  Service name (will be folder name in docker/): "
    read svc_name
    [ -z "$svc_name" ] && {
        warn "Name cannot be empty"
        pause
        return
    }

    local svc_dir="$DOCKER_ROOT/$svc_name"
    if [ -d "$svc_dir" ]; then
        fail "Directory already exists: $svc_dir"
        pause
        return
    fi

    mkdir -p "$svc_dir"
    local compose_file="$svc_dir/docker-compose.yml"
    cat >"$compose_file" <<COMPEOF
services:
  ${svc_name}:
    image: 
    container_name: ${svc_name}
    restart: unless-stopped
    volumes:
      - ${svc_dir}/config:/config
    ports:
      - "8080:8080"
COMPEOF

    ok "Created $svc_dir"
    echo -e "  ${YELLOW}Opening docker-compose.yml in nvim...${NC}\n"
    nvim "$compose_file"
    pause
}

compose_delete() {
    print_section "1.5" "Containers › Delete service"

    local services=()
    while IFS= read -r d; do
        [ -n "$d" ] && services+=("$d")
    done < <(get_services)

    if [ ${#services[@]} -eq 0 ]; then
        warn "No services found"
        pause
        return
    fi

    local i=1
    for d in "${services[@]}"; do
        local name
        name=$(basename "$d")
        local compose
        compose=$(get_compose_file "$d")
        local running
        running=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)
        local status_str
        [ "$running" -gt 0 ] &&
            status_str=" ${GREEN}● up ($running)${NC}" ||
            status_str=" ${RED}○ down${NC}"
        printf "  ${RED}%2d.${NC} %-25s%b\n" "$i" "$name" "$status_str"
        ((i++))
    done
    echo -e "  ${YELLOW}  0.${NC} Cancel"
    echo ""
    read -p "  Select service to delete: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${services[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local name
    name=$(basename "$target")

    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "  ${RED}•${NC} docker compose down for ${BOLD}$name${NC}"
    echo -e "  ${RED}•${NC} Delete entire directory: $target"
    echo ""
    echo -ne "  ${RED}Type 'delete' to confirm:${NC} "
    read confirm
    [ "$confirm" != "delete" ] && {
        echo -e "\n  ${YELLOW}Cancelled.${NC}"
        pause
        return
    }

    echo ""
    local compose
    compose=$(get_compose_file "$target")
    if [ -n "$compose" ]; then
        info "Stopping containers..."
        cd "$target" && docker compose down 2>/dev/null &&
            ok "Containers stopped" ||
            warn "Could not stop containers (may already be down)"
    fi

    info "Deleting $target..."
    rm -rf "$target" &&
        ok "$name deleted" ||
        fail "Failed to delete directory"

    pause
}

menu_containers() {
    while true; do
        print_section "1" "Containers & docker-compose.yml"
        echo -e "  ${GREEN}1.${NC} Choose service"
        echo -e "  ${GREEN}2.${NC} Up all (docker-compose.yml)"
        echo -e "  ${RED}3.${NC} Down all (docker-compose.yml)"
        echo -e "  ${GREEN}4.${NC} Create new service (docker-compose.yml)"
        echo -e "  ${RED}5.${NC} Delete service"
        echo -e "  ${CYAN}6.${NC} Junk"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) compose_choose_service ;;
        2) all_up ;;
        3) all_down ;;
        4) compose_create ;;
        5) compose_delete ;;
        6) menu_junk ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid${NC}" && sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# 3. Junk
# ─────────────────────────────────────────

junk_list() {
    print_section "1.6.1" "Junk › List"
    echo -e "  ${YELLOW}$JUNK_DIR${NC}\n"

    local found=0
    for dir in "$JUNK_DIR"/*/; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        local compose
        compose=""
        [ -f "$dir/docker-compose.yml" ] && compose="docker-compose.yml"
        [ -f "$dir/docker-compose.yaml" ] && compose="docker-compose.yaml"
        local compose_str
        [ -n "$compose" ] && compose_str="${CYAN}$compose${NC}" || compose_str="${RED}no docker-compose.yml${NC}"
        printf "  ${YELLOW}•${NC} %-25s %b\n" "$name" "$compose_str"
        found=1
    done

    [ $found -eq 0 ] && warn "Junk is empty"
    pause
}

junk_move_to() {
    print_section "1.6.2" "Junk › Move to junk"

    local services=()
    while IFS= read -r d; do
        [ -n "$d" ] && services+=("$d")
    done < <(get_services)

    if [ ${#services[@]} -eq 0 ]; then
        warn "No services found"
        pause
        return
    fi

    local i=1
    for d in "${services[@]}"; do
        local name
        name=$(basename "$d")
        local compose
        compose=$(get_compose_file "$d")
        local running
        running=$(docker compose -f "$compose" ps -q 2>/dev/null | wc -l)
        local status_str
        [ "$running" -gt 0 ] &&
            status_str=" ${GREEN}● up ($running)${NC}" ||
            status_str=" ${RED}○ down${NC}"
        printf "  ${RED}%2d.${NC} %-25s%b\n" "$i" "$name" "$status_str"
        ((i++))
    done
    echo -e "  ${YELLOW}  0.${NC} Cancel"
    echo ""
    read -p "  Select service to move to junk: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${services[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local name
    name=$(basename "$target")

    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "  ${RED}•${NC} docker compose down for ${BOLD}$name${NC}"
    echo -e "  ${RED}•${NC} Delete images used by $name"
    echo -e "  ${RED}•${NC} Move $target → $JUNK_DIR/$name"
    echo ""
    echo -ne "  ${RED}Confirm? (y/n):${NC} "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    echo ""

    # Down контейнеров
    local compose
    compose=$(get_compose_file "$target")
    if [ -n "$compose" ]; then
        info "Stopping containers..."
        cd "$target" && docker compose down 2>/dev/null &&
            ok "Containers stopped" ||
            warn "Could not stop containers (may already be down)"
    fi

    # Удалить образы сервиса
    info "Removing images..."
    local images
    images=$(docker compose -f "$compose" images -q 2>/dev/null)
    if [ -n "$images" ]; then
        echo "$images" | xargs docker rmi -f 2>/dev/null &&
            ok "Images removed" ||
            warn "Some images could not be removed"
    else
        warn "No images found for this service"
    fi

    # Переместить директорию
    info "Moving $name to junk..."
    mkdir -p "$JUNK_DIR"
    mv "$target" "$JUNK_DIR/$name" &&
        ok "$name moved to $JUNK_DIR/$name" ||
        fail "Failed to move directory"

    pause
}

junk_move_from() {
    print_section "1.6.3" "Junk › Move from junk"

    local junked=()
    for dir in "$JUNK_DIR"/*/; do
        [ -d "$dir" ] && junked+=("$dir")
    done

    if [ ${#junked[@]} -eq 0 ]; then
        warn "Junk is empty"
        pause
        return
    fi

    local i=1
    for d in "${junked[@]}"; do
        local name
        name=$(basename "$d")
        echo -e "  ${GREEN}$i.${NC} $name"
        ((i++))
    done
    echo -e "  ${YELLOW}0.${NC} Cancel"
    echo ""
    read -p "  Select service to restore: " choice
    [ "$choice" = "0" ] && return

    local idx=$((choice - 1))
    local target="${junked[$idx]}"
    [ -z "$target" ] && {
        echo -e "\n  ${RED}Invalid${NC}"
        pause
        return
    }

    local name
    name=$(basename "$target")

    # Проверить что такой папки нет в docker/
    if [ -d "$DOCKER_ROOT/$name" ]; then
        fail "Directory $DOCKER_ROOT/$name already exists"
        pause
        return
    fi

    echo ""
    echo -ne "  Move ${BOLD}$name${NC} back to $DOCKER_ROOT/? (y/n): "
    read confirm
    [ "$confirm" != "y" ] && {
        echo -e "\n  Cancelled."
        pause
        return
    }

    mv "$target" "$DOCKER_ROOT/$name" &&
        ok "$name restored to $DOCKER_ROOT/$name" ||
        fail "Failed to move directory"

    pause
}

menu_junk() {
    while true; do
        print_section "1.6" "Junk"
        echo -e "  ${GREEN}1.${NC} List junk services"
        echo -e "  ${RED}2.${NC} Move to junk"
        echo -e "  ${GREEN}3.${NC} Move from junk"
        echo -e "  ${YELLOW}0.${NC} Back"
        echo ""
        read -p "  Choice: " c
        case $c in
        1) junk_list ;;
        2) junk_move_to ;;
        3) junk_move_from ;;
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
    echo -e "  ${CYAN}1.${NC} Containers & docker-compose.yml"
    echo -e "  ${CYAN}2.${NC} Images"
    echo -e "  ${YELLOW}0.${NC} Exit"
    echo ""
    read -p "  Choice: " choice
    case $choice in
    1) menu_containers ;;
    2) menu_images ;;
    0) echo "" && exit 0 ;;
    *) echo -e "  ${RED}Invalid choice${NC}" && sleep 1 ;;
    esac
done
