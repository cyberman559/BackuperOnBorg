#!/bin/bash

project="$1"
PRIVATE_KEY_CONTENT="$2"
YAML="$3"
DB_TYPE="$4"
DB_PATH="$5"
SUDO_USER="$6"
DB_USER="$7"
shift 7

DB_NAME=("$@")

RANDOM_STRING=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
SALT="fgh56"
identity_file="/tmp/$RANDOM_STRING$SALT"
yaml_file="/tmp/$RANDOM_STRING$SALT.yaml"

function close() {
    rm -f "$identity_file"
    rm -f "$yaml_file"
}

run_as_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}

trap close EXIT

echo "$PRIVATE_KEY_CONTENT" | base64 -d > "$identity_file"
chmod 600 "$identity_file"

echo "$YAML" | base64 -d > "$yaml_file"
chmod 600 "$yaml_file"

# Проверка существования конфигурации
if [[ ! -f "$yaml_file" ]]; then
    echo "Конфигурация $yaml_file не найдена."
    exit 1
fi

export BORG_RSH="ssh -i $identity_file"

echo "Получение списка архивов..."

mapfile -t archives < <(
    borgmatic --config "$yaml_file" list --short 2>/dev/null | grep -v "Listing"      
)

if [ ${#archives[@]} -eq 0 ]; then
    echo "Архивы не найдены"
    exit 1
fi

echo
echo "Доступные архивы:"

for i in "${!archives[@]}"; do
    echo "$((i+1))) ${archives[$i]}"
done

archive="$(printf "%s\n" "${archives[@]}" | sort -r | head -n 1)"
echo "Автовыбор последнего архива: $archive"
echo "Восстанавливаю файлы"
if borgmatic --config "$yaml_file" extract --archive "$archive" --destination / 2>/dev/null; then
  echo "Done"
else
  echo "Failed to restore files."
fi

echo "Восстанавливаем базу данных"

case "$DB_TYPE" in

psql|postgres|postgresql)

  for db in "${DB_NAME[@]}"; do
    echo "Restore PostgreSQL: $db"
    sudo -u postgres psql "$db" < "$DB_PATH/$db.sql"
  done
;;

mysql)
    echo "Данный тип БД временно не доступен."
  ;;

mssql|sqlserver)
  echo "Данный тип БД временно не доступен."
;;

*)
  echo "Неизвестный DB_TYPE: $DB_TYPE"
;;

esac