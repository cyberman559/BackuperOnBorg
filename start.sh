#!/bin/bash

project="${1:-}"
force="${2:-}"
if [[ -z "$project" ]]; then
    echo "Не передан параметр project"
    exit 1
fi

function close() {
    rm -f "$FLAG_RUN"
    if [ "$VPN" == 1 ]; then
        if [ -f "/tmp/openvpn-${project}.pid" ]; then
          pkill -F "/tmp/openvpn-${project}.pid" 2>/dev/null || true
          rm -f "/tmp/openvpn-${project}.pid"
        else
          pkill openvpn || true
        fi
    fi
}

trap close EXIT

set -e

source /root/.borg/projects/${project}/settings.conf
: "${DB_TYPE:=mysql}"
: "${DB_PATH:=~}"
: "${SUDO_USER:=root}"

mkdir -p /var/borg/projects/${project}/

FLAG_FILE="/var/borg/projects/${project}/.full_last_success"
FLAG_RUN="/var/borg/projects/${project}/.run"

if [ -f "$FLAG_RUN" ]; then
    exit 0
fi

function time_to_backup() {
    if [[ ! -f "$FLAG_FILE" ]]; then
        return 0
    fi

    last_date=$(<"$FLAG_FILE")
    last_ts=$(date -d "$last_date" +%s)
    next_ts=$(date -d "$last_date +1 days" +%s)
    today_ts=$(date -d "$(date +%F)" +%s)

    if [ "$today_ts" -ge "$next_ts" ]; then
        current_time=$(date +%H%M)
        current_time=$((10#$current_time))
        if [ "$current_time" -lt 515 ]; then
            #echo "Новый день, но еще не 05:15 — откладываем запуск резервного копирования."
            return 1
        fi
        return 0
    else
        return 1
    fi
}

start_vpn() {
    local project="$1"
    local ovpn_name="$2"
    local ip="$3"

    echo "Запуск VPN"
    echo "/root/.borg/projects/${project}/${ovpn_name}.ovpn"

    openvpn --config "/root/.borg/projects/${project}/${ovpn_name}.ovpn" --daemon \
        --log "/var/log/openvpn-${project}.log" \
        --writepid "/tmp/openvpn-${project}.pid"

    sleep 10

    if ! ping -c1 -W3 "$ip" >/dev/null 2>&1; then
        echo "Нет подключения"
        pkill -F "/tmp/openvpn-${project}.pid" 2>/dev/null || true
        return 1
    fi

    echo "Подключен VPN"
    return 0
}

PRIVATE_KEY_PATH="/home/$project/.ssh/id_ed25519"
PRIVATE_KEY_CONTENT=$(base64 -w0 "$PRIVATE_KEY_PATH")

YAML="/root/.borg/projects/${project}/full.yaml"
YAML_CONTENT=$(base64 -w0 "$YAML")

if [ "$force" == "unborg" ]; then
  if [ "$VPN" == 1 ]; then 
    start_vpn "$project" "$OVPN_NAME" "$IP" || exit 1
  fi
  if ping -c1 -W3 "$IP" >/dev/null 2>&1; then
    ssh -p "$PORT" -i /root/.ssh/id_ed25519 \
      "$USER@$IP" \
      BORG_PASSPHRASE="$BORG_PASSPHRASE" bash -s -- "$project" "$PRIVATE_KEY_CONTENT" "$YAML_CONTENT" "$DB_TYPE" "$DB_PATH" "$SUDO_USER" "$DB_USER" "${DB_NAME[@]}" < /root/.borg/unborg.sh
  fi 
fi 

if time_to_backup || [[ "$force" == "force" ]]; then
    date +%F > "$FLAG_RUN"
    
    if [ "$VPN" == 1 ]; then 
      start_vpn "$project" "$OVPN_NAME" "$IP" || exit 1
    fi
    
    if ping -c1 -W3 "$IP" >/dev/null 2>&1; then
      if [ "$PROJECT_TYPE" = "1c" ]; then
          ssh -p "$PORT" -i /root/.ssh/id_ed25519 \
              "$USER@$IP" \
              "BORG_PASSPHRASE='$BORG_PASSPHRASE' wsl bash -s -- \"$project\" \"$PRIVATE_KEY_CONTENT\" \"$YAML_CONTENT\" \"$DB_TYPE\" \"$DB_PATH\" \"$SUDO_USER\" \"$DB_USER\" \"${DB_NAME[@]}\"" \
              < /root/.borg/borg.sh
      else
          ssh -p "$PORT" -i /root/.ssh/id_ed25519 \
              "$USER@$IP" \
              BORG_PASSPHRASE="$BORG_PASSPHRASE" \
              bash -s -- "$project" "$PRIVATE_KEY_CONTENT" "$YAML_CONTENT" "$DB_TYPE" "$DB_PATH" "$SUDO_USER" "$DB_USER" "${DB_NAME[@]}" \
              < /root/.borg/borg.sh
      fi
    fi
fi
