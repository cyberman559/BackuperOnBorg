#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт с правами root."
  exit 1
fi

read -p "Введите имя пользователя: " username

if id "$username" &>/dev/null; then
  echo "Пользователь $username уже существует."
else
  useradd -m "$username"
  echo "Пользователь $username создан."
fi

deluser "$username" users

backup_dir="/mnt/backups/$username"
mkdir -p "$backup_dir"
chown -R "$username":"$username" "$backup_dir"
chmod -R 700 "$backup_dir"

ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -C "borg"
echo "Публичный ключ:"
cat /root/.ssh/id_ed25519.pub
read -p "Добавьте его на клиент. Нажмите Enter, чтобы продолжить..."

ssh_dir="/home/$username/.ssh"
mkdir -p "$ssh_dir"
ssh-keygen -t ed25519 -f $ssh_dir/id_ed25519 -C "borg_client"

chown "$username":"$username" "$ssh_dir"
chmod 750 "$ssh_dir"
touch "$ssh_dir/authorized_keys"
chown root:"$username" "$ssh_dir/authorized_keys"
chmod 640 "$ssh_dir/authorized_keys"

echo "$(cat $ssh_dir/id_ed25519.pub)" >> "$ssh_dir/authorized_keys"

systemctl restart sshd

if borg list $backup_dir > /dev/null 2>&1; then
  echo "Репозиторий уже инициализирован."
else
  sudo -u $username borg init --encryption=repokey $backup_dir
  echo "Репозиторий создан."
fi

mkdir /root/.borg/projects/$username

echo "Выберите тип проекта:"
echo "1 - битрикс"
echo "2 - laravel"
echo "3 - 1с"
read -p "Введите номер: " project_type
case $project_type in
  1) yaml_name="bitrix" ;;
  2) yaml_name="lara" ;;
  #3) yaml_name="1c" ;;
  *) echo "Неверный выбор"; exit 1 ;;
esac

sed "s/{{PROJECT}}/$(printf %q "$username")/g" /root/.borg/$yaml_name.yaml.example > /root/.borg/projects/$username/full.yaml
if [[ ! -f /root/.borg/projects/$username/settings.conf ]]; then
  cp /root/.borg/settings.conf.example /root/.borg/projects/$username/settings.conf
fi

echo "Не забудь исправить /root/.borg/projects/$username/$yaml_name.yaml и /root/.borg/projects/$username/$username.conf"

echo "Завершено!"