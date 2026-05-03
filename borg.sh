#!/bin/bash

project="$1"
PRIVATE_KEY_CONTENT="$2"
YAML="$3"
DB_TYPE="$4"
DB_PATH="$5"
SUDO_USER="$6"
shift 6

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

dump_base_skip_stat=1
dump_base_skip_search=1
dump_base_skip_log=1


case "$DB_TYPE" in

mysql)
for db in "${DB_NAME[@]}"; do
    all_tables=($(mysql -N -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db';"))

    IGNORE_ARGS=()

    for table in "${all_tables[@]}"; do
        table_lower=$(echo "$table" | tr '[:upper:]' '[:lower:]')

        # Проверка условий исключения
        if [[ $dump_base_skip_stat -eq 1 && "$table_lower" =~ ^b_stat ]]; then
            IGNORE_ARGS+=(--ignore-table="$db.$table")
            continue
        fi

        if [[ $dump_base_skip_search -eq 1 && "$table_lower" =~ ^b_search_ ]]; then
            if [[ ! "$table_lower" =~ ^b_search_custom_rank$ && ! "$table_lower" =~ ^b_search_phrase$ ]]; then
                IGNORE_ARGS+=(--ignore-table="$db.$table")
                continue
            fi
        fi

        if [[ $dump_base_skip_log -eq 1 && "$table_lower" == "b_event_log" ]]; then
            IGNORE_ARGS+=(--ignore-table="$db.$table")
            continue
        fi
    done
    mkdir -p /home/bitrix/db_dumps
    mysqldump "${IGNORE_ARGS[@]}" "$db" > "/home/bitrix/db_dumps/$db.sql"
    if [[ $? -ne 0 ]]; then
        echo "Ошибка создания дампа базы данных."
    fi
done
;;

psql|postgres|postgresql)

for db in "${DB_NAME[@]}"; do
    echo "Dump PostgreSQL: $db"

    mapfile -t all_tables < <(
      psql -d "$db" -At -c "SELECT tablename FROM pg_tables WHERE schemaname='public';"
    )

    EXCLUDE_ARGS=()

    for table in "${all_tables[@]}"; do
      table_lower=$(echo "$table" | tr '[:upper:]' '[:lower:]')

      if [[ ${dump_base_skip_stat:-0} -eq 1 && "$table_lower" =~ ^b_stat ]]; then
        EXCLUDE_ARGS+=(--exclude-table="$table")
        continue
      fi

      if [[ ${dump_base_skip_search:-0} -eq 1 && "$table_lower" =~ ^b_search_ ]]; then
        if [[ ! "$table_lower" =~ ^b_search_custom_rank$ && ! "$table_lower" =~ ^b_search_phrase$ ]]; then
          EXCLUDE_ARGS+=(--exclude-table="$table")
          continue
        fi
      fi

      if [[ ${dump_base_skip_log:-0} -eq 1 && "$table_lower" == "b_event_log" ]]; then
        EXCLUDE_ARGS+=(--exclude-table="$table")
        continue
      fi
    done

    run_as_user pg_dump "$db" "${EXCLUDE_ARGS[@]}" > "$DB_PATH/$db.sql" || {
      echo "Ошибка дампа PostgreSQL: $db"
      exit 1
    }
  done
;;

mssql|sqlserver)
  echo "Данный тип БД временно не доступен."
;;

*)
  echo "Неизвестный DB_TYPE: $DB_TYPE"
  echo "Дамп базы данных не создан."
;;

esac

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
borgmatic --config "$yaml_file" --verbosity 1
if [[ $? -ne 0 ]]; then
    echo "Ошибка при запуске borgmatic для проекта ${project}"
    exit 1
fi

echo "Бэкап проекта ${project} успешно завершён."