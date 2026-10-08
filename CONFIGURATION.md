# Конфігурація для іншої машини

Профіль описує вимоги до системи; скрипт звіряє їх із фактичною топологією.
Налаштування дисків, сховища й розкладу зберігаються окремо від коду.
Користувацькі конфіги зберігаються у `configs/` і ігноруються Git.
В репозиторії лишаються лише детально прокоментовані `*.example.jsonc`.
Підтримуються JSON та коментарі `//` на окремих рядках; inline-коментарі
і блоки `/* ... */` не підтримуються. Генератор типово пише звичайний
JSON у `configs/`; `--output-dir` дозволяє обрати інший каталог.

Робочі файли:

- `configs/backup-config.json` — що саме вважати системним backup і як обробляти
  схему root/LUKS/`/home`;
- `/etc/system-backup/service.json` — де лежить backup-диск, розклад,
  retention і параметри systemd-обгортки.

Повний порядок підготовки диска, встановлення залежностей, створення
конфігів, ініціалізації restic та першого backup — у
[README.md](README.md#3-налаштування-на-новій-машині). Python використовує
стандартну бібліотеку; окреме середовище чи пакети pip не потрібні.

Нижче — генератор та довідник полів. Альтернативно можна скопіювати
`configs/backup-config.example.jsonc` і `configs/service-config.example.jsonc`, відредагувати
їх для своєї машини та перевірити командами `validate`.

## Створення конфігів

Генератор створює два JSON-файли, перевіряє їх і визначає UUID вже
змонтованого backup-диска. Він не встановлює службу, не створює restic
репозиторій та не перезаписує наявні конфіги.

```bash
python3 scripts/configure-system-backup.py \
  --profile lvm-luks-uefi \
  --home exclude \
  --backup-mount /mnt/backup \
  --backup-dir /mnt/backup/system-backups \
  --output-dir "$PWD/configs" \
  --schedule 20:00 \
  --notice-user "$USER"
```

Замініть `/mnt/backup` фактичним mount вашого диска. Код може залишатися
в робочому каталозі: `code_dir` і `backup_dir` незалежні. У storage-каталозі
будуть `restic/`, `recovery-metadata/`, lock та журнал.

Профілі: `auto`, `lvm-luks-uefi`, `lvm-plain`, `partition-luks`,
`partition-plain`. Це початкові вимоги, які можна редагувати в JSON:
LVM-профілі вимагають snapshot, partition-профілі використовують live
backup, `luks` вимагає шифрування, `plain` вимагає його відсутності.
UEFI-профіль вимагає змонтований ESP. RAID, VG із кількома PV та складні
багатодискові root-схеми наразі не підтримуються.

Якщо `/home` на окремому mount, генератор вимагає явного вибору:

- `--home restic`: копіювати `/home` у **той самий репозиторій**, окремим
  snapshot із тегом `system-home` і спільним тегом запуску; retention
  застосовується також до нього;
- `--home exclude`: пропустити окремий `/home`;
- `--home external`: пропустити, позначивши, що його backup ведеться окремо;
- `--home auto`: включати лише `/home`, який є частиною root filesystem.

Якщо `/home` на root filesystem, виберіть `auto`: він уже входить у root
backup. Визначальною є межа filesystem, а не фізичний диск: окремий розділ
`/home` на тому самому диску теж потребує вибору.

Перегляд плану можливий до створення restic-репозиторію і без його пароля;
план та dry-run не створюють lock чи записів у backup-history:

```bash
sudo bash backup-system.sh --config configs/backup-config.json \
  --backup-dir /mnt/backup/system-backups --print-plan
```

Повне налаштування за створеними конфігами виконується однією командою:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.json"
```

Скрипт встановлює відсутні залежності, налаштовує `fstab` за UUID,
монтує диск, встановлює службу, готує пароль і новий restic-репозиторій,
виконує dry-run та backup. Після нового успішного backup вмикає таймер.
Для збереження вимкненого таймера додайте `--no-enable`.
Наявні пароль, репозиторій та узгоджений запис у `fstab` зберігаються;
повторний запуск виконує ще один backup. Диск не форматується.
Докладні кроки та ручний варіант — у [README.md](README.md).

Для оновлення лише службових файлів використовуйте
`scripts/install-system-backup.sh`:

`install --config FILE` застосовує саме цей service-конфіг, включно під час
повторної інсталяції. Без `--config` встановлений `/etc` конфіг зберігається.
Новий таймер не вмикається автоматично; вже увімкнений не вимикається. Профіль лишається за шляхом
`backup_profile`, тому цей файл і `code_dir` мають бути доступні службі.

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
звичайному block-диску й включений через `restic`, зберігається його
таблиця розділів: `home-disk.sfdisk`, а для GPT — також `home-disk.gpt`.
Для filesystem безпосередньо на всьому диску таблиці немає; manifest
позначає це явно, без фіктивних GPT-файлів. Для виключеного `/home`
його таблиця не зберігається; для LV/мережевого mount у manifest лишається точний
source, але схема нижнього storage потребує окремої recovery-процедури.

## `service.json`

Приклад — `configs/service-config.example.jsonc`. Він не містить пароль: пароль
живе окремо в root-only файлі, на який посилається `restic_password_file`.
Важливі поля:

- `backup_mount` і `backup_disk_uuid`: служба спершу перевіряє, що саме цей
  диск змонтовано; це не дає зробити backup у порожню локальну директорію;
- `backup_dir`: каталог сховища бекапів усередині mount;
- `code_dir`: каталог коду; за відсутності використовується `backup_dir`
  для сумісності з конфігами попередньої версії;
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
`configs/service-config.json` поруч із прикладом: інсталятор перевірить і скопіює
його до `/etc/system-backup/service.json`. Після першої інсталяції
канонічна робоча копія — саме файл у `/etc`; інсталятор зберігає його й
пароль, але перегенеровує залежності mount unit (`Requires`/`After`) та час timer. Сам backup-диск все одно має бути описаний у `/etc/fstab` через UUID
і `nofail`.

Не копіюйте `configs/service-config.example.jsonc` без редагування: замініть усі
`USER`, mount path і `PUT-BACKUP-DISK-UUID-HERE`, потім перевірте файл:

```bash
cp configs/service-config.example.jsonc configs/service-config.jsonc
# відредагуйте configs/service-config.jsonc для конкретної машини
python3 scripts/service-config.py validate --config configs/service-config.jsonc
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.jsonc"
```

## Межа поточної реалізації restore

`backup-system.sh` уже збирає metadata для LVM/LUKS і простіших схем. Проте
автоматизований `restore-system.sh` наразі навмисно дозволяє руйнівне
відновлення лише для перевіреного профілю `lvm-luks-uefi`. Якщо
`layout.json` описує інший профіль, він зупиниться до змін на цільовому
диску. Це запобіжник: процедуру розбиття та завантаження для нової топології
треба спершу реалізувати й перевірити на тестовому SSD.

Для відновлення зі сховища, відокремленого від коду, передайте
`restore-system.sh --backup-dir /mnt/backup/system-backups`. Нові metadata
містять UUID filesystem, щоб відновлення не залежало від імені NVMe.
Live-root, вимкнений boot backup та root/boot з filesystem, відмінною від
ext4, не підтримуються цим автоматичним restore. Окремий `system-home`
потрібно відновлювати окремо через restic; restore-system.sh його не копіює.
