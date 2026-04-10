#!/bin/bash

# LOG folder
LOG_DIR="/root/linux-all/logs/backups/"
mkdir -p "$LOG_DIR"

# LOG name + date
LOG_FILE="${LOG_DIR}/log_$(date '+%Y-%m-%d').log"

# ========= LOG FUNCTION =========
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >>"$LOG_FILE"
}

# ========= RUN COMMAND EXECUTION =========
run_step() {
    local name="$1"
    shift

    log "Start: $name"
    #log "CMD: $*"

    # Run command, redirect ALL output to log, keep correct exit code
    (
        "$@"
        cmd_exit_code=$?
        #echo "$(date '+%Y-%m-%d %H:%M:%S') | CMD exit_code=${cmd_exit_code}"
        exit "$cmd_exit_code"
    ) >>"$LOG_FILE" 2>&1

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR: $name failed with exit code $exit_code"
        return $exit_code
    else
        log "End: $name"
        return 0
    fi
}

log "-- ======================================================= --"
log "=== BACKUP START ==="

# ========= MIGRATIONS =========

run_step "Local root .config sync" /usr/sbin/rsync -a --delete /root/.config/ /root/linux-all/git/config-files/root.config/
run_step "Local fstab sync" /usr/sbin/rsync -a --delete /etc/fstab /root/linux-all/git/config-files/etc/fstab
run_step "Local motd sync" /usr/sbin/rsync -a --delete /etc/motd /root/linux-all/git/config-files/etc/motd
run_step "Local dnf sync" /usr/sbin/rsync -a --delete /etc/dnf/ /root/linux-all/git/config-files/etc/dnf/
run_step "Local nginx sync" /usr/sbin/rsync -a --delete /etc/nginx/ /root/linux-all/git/config-files/etc/nginx/
run_step "Local default sync" /usr/sbin/rsync -a --delete /etc/default/ /root/linux-all/git/config-files/etc/default/
run_step "Local letsencrypt sync" /usr/sbin/rsync -a --delete /etc/letsencrypt/ /root/linux-all/git/config-files/etc/letsencrypt/
#run_step "Local samba sync" /usr/sbin/rsync -a --delete /etc/samba/ /root/linux-all/git/config-files/etc/samba/
#run_step "Local transmission-daemon-etc sync" /usr/sbin/rsync -a --delete /etc/transmission-daemon/ /root/linux-all/git/config-files/etc/transmission-daemon/
#run_step "Local transmission-daemon-var sync" /usr/sbin/rsync -a --delete /var/lib/transmission/.config/transmission-daemon/ /root/linux-all/var/lib/transmission/.config/transmission-daemon/
#run_step "Local docker-var sync" /usr/sbin/rsync -a --delete /var/lib/docker/ /root/linux-all/var/lib/docker/
#run_step "Local wireguard sync" /usr/sbin/rsync -a --delete /etc/wireguard/ /root/linux-all/git/config-files/etc/wireguard/
run_step "Local systemd sync" /usr/sbin/rsync -a --delete /etc/systemd/ /root/linux-all/git/config-files/etc/systemd/
run_step "Local resolv.conf sync" /usr/sbin/rsync -a --delete /etc/resolv.conf /root/linux-all/git/config-files/etc/resolv.conf
run_step "Local linux-all copy" /usr/sbin/rsync -a --delete /root/linux-all/ /root/linux-all-copy/
#run_step "Local linux-all mergerfs-7tb copy" /usr/sbin/rsync -a --delete /root/linux-all/ /mnt/mergerfs-7tb/backups/linux-all/
run_step "Local linux-all sync" /usr/sbin/rsync -a --delete /root/linux-all/ /mnt/nas/nas/01-Main/01-Important/01-backups/os/linux-all/
run_step "ssh to pi linux-all sync" /usr/sbin/rsync -a --delete /mnt/nas/ malina-ssd:/mnt/nas/

log "=== BACKUP END ==="
log "-- ======================================================= --"
