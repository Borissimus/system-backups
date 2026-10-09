# Автономний backup через systemd

Служба виконує автономний щоденний backup (типово о 20:00). Сон машини,
Wake-on-LAN і BIOS RTC **навмисно не реалізовані**: їх буде додано лише після
окремого тесту апаратного пробудження.

## Компоненти

- `system-backup.service` запускає `backup-system.sh --prune` під root.
- `system-backup.timer` запускає його в час із `service.json` і не надолужує
  пропущений час.
- `system-backup-failure.service` створює `/var/lib/system-backup/failure-notice`.
- `scripts/system-backup-after-success.sh` — безпечна callback-заглушка.
- `scripts/system-backupctl.sh` — інсталяція, ручний запуск і контроль.

## Повне налаштування

Після створення конфігів:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.json"
```

Скрипт готує mount, залежності, службу, пароль і restic-репозиторій,
виконує перший backup та вмикає таймер лише після успіху. Для backup без
увімкнення таймера додайте `--no-enable`. Повторний запуск зберігає
наявні пароль і repository та виконує ще один backup. Деталі — у
[BACKUP.md](BACKUP.md#34-налаштування-одним-скриптом).

## Ручне ввімкнення

Підготовка нової машини та команди `restic init` / `--dry-run` наведені
в [BACKUP.md](BACKUP.md#3-налаштування-на-новій-машині).

```bash
# 0. Backup-диск змонтований через /etc/fstab за UUID.
#    Конфіги створені, а restic repository підготовлений за BACKUP.md.

# 1. Встановити файли і root-only пароль, але не вмикати timer.
#    Для нового repository після install виконайте restic init за BACKUP.md.
scripts/system-backupctl.sh install --config "$PWD/configs/service-config.json"

# 2. Виконати один запуск як service та оглянути журнал
scripts/system-backupctl.sh run
scripts/system-backupctl.sh logs

# 3. Лише після успіху ввімкнути timer
scripts/system-backupctl.sh enable
scripts/system-backupctl.sh timer
```

Після зміни `/etc/system-backup/service.json` знову виконайте
`scripts/system-backupctl.sh install`: він збереже JSON і пароль, але
перегенерує systemd settings для mount та часу запуску.

Політика retention, час, UUID/mount backup-диска та шлях до профілю задаються
в `/etc/system-backup/service.json`:
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

## Монтування backup-диска

Backup-диск має монтуватися systemd через `/etc/fstab`, а не лише через
файловий менеджер (udisks). Використовуйте UUID, а не нестабільне ім'я
`/dev/sdX`, і `nofail`, щоб відсутність backup-диска не блокувала boot:

```fstab
UUID=<backup_disk_uuid> <backup_mount> ext4 defaults,nosuid,nodev,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s 0 2
```

Інсталятор генерує `Wants` та `After` для mount unit із `backup_mount`
у JSON (шлях екранується через `systemd-escape`).
Тому якщо диск підключили вже після boot, service все одно спробує змонтувати
його перед backup; якщо диска немає, спрацює звичайний failure-notice.
