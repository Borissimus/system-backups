# Systemd automation (work in progress)

Ця гілка додає автономний щовечірній запуск backup о 20:00. Сон машини,
Wake-on-LAN і BIOS RTC **навмисно не реалізовані**: їх буде додано лише після
окремого тесту апаратного пробудження.

## Компоненти

- `system-backup.service` запускає `backup-system.sh --prune` під root.
- `system-backup.timer` запускає його о 20:00 і не надолужує пропущений час.
- `system-backup-failure.service` створює `/var/lib/system-backup/failure-notice`.
- `scripts/system-backup-after-success.sh` — безпечна callback-заглушка.
- `scripts/system-backupctl.sh` — інсталяція, ручний запуск і контроль.

## Порядок безпечного ввімкнення

```bash
# 1. Встановити файли і root-only пароль, але не вмикати таймер
scripts/system-backupctl.sh install

# 2. Виконати один запуск як service та оглянути журнал
scripts/system-backupctl.sh run
scripts/system-backupctl.sh logs

# 3. Лише після успіху ввімкнути щовечірній timer
scripts/system-backupctl.sh enable
scripts/system-backupctl.sh timer
```

Політика retention задається в `/etc/system-backup/system-backup.conf`:
7 щоденних, 4 тижневих і 6 місячних snapshots. Після кожного backup
виконується `prune`, який звільняє тільки дані, не потрібні жодному
збереженому snapshot.

Якщо service падає, на наступному інтерактивному Bash запускається лише
універсальний source-hook з `~/.bashrc`; він друкує динамічно створений
`failure-notice`. Notice містить останні рядки systemd journal, тому причина
помилки доступна навіть коли сам backup-диск від'єднаний і
`backup-history.log` прочитати неможливо. Після перегляду:

```bash
scripts/system-backupctl.sh acknowledge
```
