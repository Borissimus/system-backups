# Конфігурація для іншої машини

Код у репозиторії не містить імен дисків, UUID, шляху монтування чи пароля.
Кожна машина має два локальні JSON-файли, які навмисно додані до `.gitignore`:

- `backup-config.json` — що саме вважати системним backup і як обробляти
  схему root/LUKS/`/home`;
- `/etc/system-backup/service.json` — де лежить backup-диск, розклад,
  retention і параметри systemd-обгортки.

Почати можна так:

```bash
cp backup-config.example.json backup-config.json
python3 scripts/backup-config.py validate --config backup-config.json
```

Інсталятор створює цей файл автоматично, якщо його ще немає. Він також
створює `/etc/system-backup/service.json` з фактичними mount path та UUID
поточного backup-диска. Перевірка конфігів не виконує backup і нічого не
змінює.

## `backup-config.json`

`root.snapshot_mode`:

- `auto` — якщо `/` є LVM LV, використовує read-only LVM snapshot; в іншому
  випадку backup робиться з live filesystem;
- `lvm` — вимагати LVM snapshot і завершитися помилкою, якщо root не LVM;
- `live` — не створювати LVM snapshot навіть на LVM.

Live backup без LVM придатний для звичайної системи, але не є строго
атомарним знімком: файл, який активно змінюється під час читання, може
потрапити в backup у проміжному стані. Для баз даних і VM потрібен їхній
власний dump/stop hook або LVM/ZFS/Btrfs snapshot.

`encryption.mode`:

- `auto` — за наявності LUKS під root зберегти LUKS header;
- `required` — не запускатися, якщо LUKS не виявлено;
- `none` — не запускатися, якщо LUKS виявлено. Це захист від застосування
  неправильного профілю, а не команда вимкнути шифрування.

`boot.mode`:

- `auto` — окремо backup `/boot`, а за наявності — і `/boot/efi`;
- `required` — вимагати змонтований ESP (`/boot/efi`);
- `none` — свідомо не робити окремий boot snapshot. Використовуйте лише коли
  `/boot` гарантовано входить до root backup або ви маєте інший спосіб його
  відновлення.

`home` — найважливіше для окремого диска:

- `auto`: коли `/home` на root filesystem, він уже входить до system-root;
  коли це окремий mount, він **не** копіюється окремо;
- `restic`: дозволено лише для окремо змонтованого `/home`; створює окремий
  `system-home` snapshot у live режимі;
- `external`: `/home` не входить у цей backup — користувач веде його в іншій
  синхронізації/backup-системі;
- `exclude`: те саме виключення, але без твердження, що інша копія існує.

Для `external` та `exclude` скрипт відмовиться працювати, якщо `/home` на
тому самому filesystem, що й `/`: це запобігає непомітному пропуску даних.
`home.snapshot_mode` поки має єдине чесне значення `live`.

Кожен прогін зберігає у `recovery-metadata/layout.json` виявлену топологію,
обраний профіль, generic GPT/sfdisk/LUKS/LVM metadata і факт, чи окремий
`/home` реально потрапив у цей запуск. Якщо `/home` лежить на іншому
звичайному block-диску, також зберігаються `home-disk.gpt` та
`home-disk.sfdisk`; для LV/мережевого mount у manifest лишається точний
source, але схема нижнього storage потребує окремої recovery-процедури.

## `service.json`

Приклад — `service-config.example.json`. Він не містить пароль: пароль
живе окремо в root-only файлі, на який посилається `restic_password_file`.
Важливі поля:

- `backup_mount` і `backup_disk_uuid`: служба спершу перевіряє, що саме цей
  диск змонтовано; це не дає зробити backup у порожню локальну директорію;
- `backup_dir`: каталог цього репозиторію всередині mount;
- `backup_profile`: шлях до `backup-config.json`; порожній рядок означає
  built-in безпечні `auto` defaults;
- `schedule`: локальний час `HH:MM`;
- `retention`: кількість daily/weekly/monthly snapshot'ів кожного типу;
- `min_repository_free_gib`: межа, нижче якої служба відмовляється стартувати.

Після зміни `service.json` виконайте:

```bash
sudo bash scripts/install-system-backup.sh
system-backupctl timer
```

Перед першим запуском можна підготувати локальний (ігнорований Git)
`service-config.json` поруч із прикладом: інсталятор перевірить і скопіює
його до `/etc/system-backup/service.json`. Після першої інсталяції
канонічна робоча копія — саме файл у `/etc`; інсталятор зберігає його й
пароль, але перегенеровує systemd drop-in з `RequiresMountsFor` та часом
timer. Сам backup-диск все одно має бути описаний у `/etc/fstab` через UUID
і `nofail`.

## Межа поточної реалізації restore

`backup-system.sh` уже збирає metadata для LVM/LUKS і простіших схем. Проте
автоматизований `restore-system.sh` наразі навмисно дозволяє руйнівне
відновлення лише для перевіреного профілю `lvm-luks-uefi`. Якщо
`layout.json` описує інший профіль, він зупиниться до змін на цільовому
диску. Це запобіжник: процедуру розбиття та завантаження для нової топології
треба спершу реалізувати й перевірити на тестовому SSD.
