# system-backups — резервне копіювання та відновлення

Цей каталог — самодостатній комплект для backup системи через
[restic](https://restic.net/). `backup-system.sh` підтримує LVM-on-LUKS і
простіші root-схеми; для поточного, перевіреного LVM-on-LUKS UEFI профілю є
процедура recovery в [RECOVERY.md](RECOVERY.md). Нижче — створення
конфігів і запуск на новій машині. Деталі полів профілю — у
[CONFIGURATION.md](CONFIGURATION.md), керування службою — у
[AUTOMATION.md](AUTOMATION.md).

Автоматичне відновлення підтримує LVM-on-LUKS/UEFI із LVM snapshot,
окремим `/boot` та ext4 для root/boot. Інші підтримувані схеми можна
бекапити, але їх відновлення потребує окремої процедури. Окремий `/home`
також відновлюється окремо через restic.

## Зміст проєкту

| Файл/каталог              | Призначення |
|----------------------------|-------------|
| `restic/`                  | Сам restic-репозиторій (зашифрований, content-addressed) |
| `recovery-metadata/`       | GPT/LUKS-заголовок/LVM-конфіг оригінального диска — оновлюється щобекапу |
| `backup-system.sh`         | Створення нового бекапу (цей документ) |
| `restore-system.sh`        | Повне відновлення на новий диск |
| `scripts/setup-system-backup.sh` | Повне налаштування за готовими конфігами та перший backup |
| `scripts/configure-system-backup.py` | Створення узгоджених backup/service конфігів |
| `configs/backup-config.example.jsonc` | Приклад profile root/LUKS/boot/home для конкретної машини |
| `configs/service-config.example.jsonc` | Приклад JSON-параметрів systemd-служби без секретів |
| `backup-history.log`       | Журнал історії запусків `backup-system.sh` (створюється автоматично) |
| `.backup.lock`             | Lock-файл проти паралельних запусків (створюється автоматично) |
| `.restore-progress` / `.restore-cache` | Службові файли `restore-system.sh` (resume/кеш) |

Код і сховище можуть лежати окремо. `restic/`, `recovery-metadata/`, журнал,
lock і стан відновлення створюються в `backup_dir`; без `--backup-dir` —
поруч зі скриптом. Локальні конфіги у `configs/` і дані сховища ігноруються Git.
У `configs/` версіонуються лише `*.example.jsonc` — детальні приклади
з коментарями `//` на окремих рядках. Валідатори й скрипти читають як
звичайний JSON, так і цей формат; inline-коментарі та `/* ... */` не підтримуються.
Робочий service-конфіг після інсталяції також зберігається у
`/etc/system-backup/service.json`.

---

## 1. Що робить `backup-system.sh`

Запускається **на вже встановленій і завантаженій системі** (не з Live
USB — для цього є `restore-system.sh`). За один прогін:

1. Автовизначає storage-конфігурацію (`/`, за наявності VG/LV і LUKS,
   диск, `/boot`, `/boot/efi`) — імена дисків не хардкодяться. Profile у
   `backup-config.json` може вимагати або забороняти окремі складники.
2. Рахує безпечний розмір тимчасового LVM-снепшоту
   (`min(вільне у VG − 1G, 20% розміру LV)`, мінімум 5G, інакше — явна
   помилка з поясненням, скільки бракує).
3. Оновлює `recovery-metadata/` (GPT, sfdisk, blkid, а за потреби LVM-конфіг,
   LUKS header і metadata фізично окремого home-диска) — щоб recovery мав
   актуальні дані, а не знімок з дня першого бекапу.
4. Якщо root — LVM і профіль не вимагає `live`, створює LVM-снепшот кореня з унікальним іменем
   `root-backup-snapshot-YYYYMMDD-HHMMSS` — **консистентна точка в часі**,
   не повна копія; монтує його read-only у сталий шлях
   `/mnt/root-backup-snapshot`.
5. Викликами `restic backup` заливає корінь, `/boot`, свіжі
   `recovery-metadata` і, якщо профіль так задає, окремий `/home`. Типи
   мають теги `system-root` / `system-boot` / `recovery-metadata` /
   `system-home` плюс унікальний `run-<timestamp>` на кожен прогін.
6. Прибирає снепшот, опційно застосовує retention (`--prune`), робить
   швидку перевірку репозиторію (`restic check`, без читання даних).

## 2. Чому це не дублює дані щоразу

- **restic — content-addressed сховище.** Кожен шматок даних (chunk)
  зберігається один раз за хешем вмісту, незалежно від того, з якого
  файлу/snapshot'у він прийшов. Навіть якщо parent snapshot не знайдено
  (див. нижче), уже наявний за хешем блок ніколи не заливається вдруге.
- **Автоматичний parent snapshot.** `restic backup <шлях>` сам шукає
  останній snapshot з тим самим (hostname, шлях) і використовує його як
  базу для швидкого визначення змінених файлів (за mtime+size, без
  повного перечитування вмісту незмінених файлів). Для LVM snapshot шлях
  `/mnt/root-backup-snapshot` сталий незалежно від імені тимчасового LV.
- **LVM-снепшот — не повна копія.** Це лише copy-on-write шар для
  консистентності на час бекапу (кілька хвилин); сам знімок займає лише
  стільки місця, скільки даних змінилося ПІД ЧАС бекапу (звідси й
  динамічний розрахунок розміру, а не фіксовані сотні гігабайт).

## 3. Налаштування на новій машині

Виконуйте команди з кореня цього Git-проєкту. Приклад використовує
`/backup/system` як mount backup-диска і `/backup/system/system-backups`
як каталог сховища. Замініть їх своїми шляхами. Якщо будь-який крок
завершився помилкою, усуньте її перед наступним.

### 3.1 Залежності й схема системи

Для Ubuntu/Debian:

```bash
sudo apt update
sudo apt install restic lvm2 cryptsetup gdisk fdisk python3 util-linux
lsblk -o NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS
findmnt --target /
findmnt --target /home
```

Скрипт `setup-system-backup.sh` сам встановлює відсутні залежності.
Для запуску генератора конфігів заздалегідь потрібні `python3` і util-linux.
Python використовує лише стандартну бібліотеку: `venv` і `pip install`
не потрібні. Служба запускає системний `python3`.

### 3.2 Backup-диск

Використовуйте вже підготовлений диск із filesystem. Визначте його UUID
через `lsblk` вище та додайте до `/etc/fstab` рядок із **власним UUID**:

```bash
sudo mkdir -p /backup/system
sudo cp -n /etc/fstab /etc/fstab.before-system-backup
sudoedit /etc/fstab
```

```fstab
UUID=<UUID_BACKUP_DISK> /backup/system ext4 defaults,nosuid,nodev,nofail,x-systemd.device-timeout=10s,x-systemd.mount-timeout=30s 0 2
```

Приклад передбачає ext4 на backup-диску. Після редагування:

```bash
sudo systemctl daemon-reload
sudo mount /backup/system
findmnt --mountpoint /backup/system
df -h /backup/system
```

Звірте source та UUID з вибраним диском. Служба також перевірятиме UUID
перед кожним запуском.

### 3.3 Створення конфігів під систему

Виберіть початковий профіль за фактичною схемою root:

| `--profile` | Root backup | Шифрування під root | Boot |
|-------------|-------------|--------------------|------|
| `lvm-luks-uefi` | LVM snapshot | LUKS обов'язковий | ESP обов'язковий |
| `lvm-plain` | LVM snapshot | LUKS має бути відсутній | auto |
| `partition-luks` | live filesystem | LUKS обов'язковий | auto |
| `partition-plain` | live filesystem | LUKS має бути відсутній | auto |
| `auto` | LVM snapshot, якщо доступний; інакше live | автовизначення | auto |

Профіль задає вимоги; скрипт перевіряє їх перед backup. Live backup не є
атомарним знімком активно змінюваних даних. Обмеження storage-схем і
деталі режимів описані в [CONFIGURATION.md](CONFIGURATION.md).

Для `/home` виберіть:

- `--home auto`, якщо він на root filesystem: вже входить до root backup;
- `--home restic`, щоб включити окремо змонтований `/home` у **той самий
  restic-репозиторій**, окремим snapshot `system-home`;
- `--home exclude`, щоб пропустити окремо змонтований `/home`;
- `--home external`, якщо backup окремого `/home` ведеться іншою системою.

Важлива межа filesystem: окремий `/home` на тому самому фізичному диску
теж потребує вибору. Якщо `/home` змонтований окремо, генератор вимагає
явного `--home`; без вибору він не створить конфіги.

Приклад: root у LVM усередині LUKS, UEFI, окремий `/home` пропускаємо:

```bash
python3 scripts/configure-system-backup.py \
  --profile lvm-luks-uefi \
  --home exclude \
  --backup-mount /backup/system \
  --backup-dir /backup/system/system-backups \
  --output-dir "$PWD/configs" \
  --schedule 20:00 \
  --notice-user "$USER"

python3 scripts/backup-config.py validate --config configs/backup-config.json
python3 scripts/service-config.py validate --config configs/service-config.json
cat configs/backup-config.json
cat configs/service-config.json
```

Генератор визначає UUID змонтованого backup-диска та створює:

- `backup-config.json`: root/LUKS/boot/home;
- `service-config.json`: шлях до коду, сховище, UUID, розклад і retention.

Наявні конфіги не перезаписуються. Для нового варіанта виберіть інший
`--output-dir` або відредагуйте існуючі JSON та повторіть validate.
Код може залишатися у вашому робочому каталозі. Генератор не створює
restic-репозиторій і не встановлює службу.

### 3.4 Налаштування одним скриптом

Після створення та перевірки конфігів запустіть:

```bash
sudo bash scripts/setup-system-backup.sh --config "$PWD/configs/service-config.json"
```

Це основний спосіб інсталяції. Скрипт:

1. Встановлює відсутні залежності через `apt-get` на Ubuntu/Debian.
2. Перевіряє конфіги, пристрій і UUID backup-диска; додає запис у
   `/etc/fstab`, якщо його немає, та монтує диск. Перед зміною створює
   `/etc/fstab.before-system-backup`; чужий запис для цього mount не змінює.
3. Перевіряє вільне місце та план backup.
4. Вимикає таймер на час налаштування, встановлює службові файли й
   root-only пароль. Якщо пароля ще немає, запитує його інтерактивно.
5. Ініціалізує новий restic-репозиторій; наявний зберігає. Непорожній
   каталог без restic `config` потребує ручного огляду.
6. Виконує `--dry-run`, перший backup через службу та перевіряє новий
   запис `status=success` у журналі.
7. Лише після успіху вмикає щоденний таймер за `schedule`.

Форматування і розбиття диска не виконуються. Backup-диск має вже містити
ext4, XFS або Btrfs і бути підключеним. Генератор конфігів потребує вже
змонтованого диска; якщо диск змонтований файловим менеджером, можна
використати цей mount у конфігу — setup додасть його до `fstab`. Для служби
зручніше обрати постійний шлях, як у розділі 3.2.

Повторний запуск застосовує переданий service-конфіг, зберігає пароль
і репозиторій та виконує ще один backup. Він не дублює запис у `fstab`.
Якщо налаштування падає після вимкнення таймера, таймер лишається вимкненим;
усуньте причину й повторіть команду. Конфліктний mount чи `fstab` запис
скрипт просить перевірити вручну.

Для інсталяції та першого backup без увімкнення розкладу:

```bash
sudo bash scripts/setup-system-backup.sh \
  --config "$PWD/configs/service-config.json" --no-enable
```

Під час backup можна дивитися журнал в іншому терміналі:

```bash
sudo journalctl -u system-backup.service -f
```

Після успіху переходьте до перевірок із розділу 3.7. Наступні два розділи
містять ручний варіант тих самих дій для діагностики.

### 3.5 Ручне налаштування: план, пароль і репозиторій

Перегляньте план до будь-якого backup, без пароля репозиторію:

```bash
sudo bash backup-system.sh \
  --config "$PWD/configs/backup-config.json" \
  --backup-dir /backup/system/system-backups \
  --print-plan
```

Підготуйте каталог і встановіть службу без увімкнення таймера:

```bash
sudo install -d -m 0700 /backup/system/system-backups
sudo bash scripts/install-system-backup.sh --config "$PWD/configs/service-config.json"
```

Інсталятор попросить пароль restic та збереже його у root-only файлі
`/etc/system-backup/restic.pass`. Наявний файл пароля зберігається.
Збережіть пароль також для відновлення. Інсталятор додає повідомлення
про помилки до інтерактивного Bash користувача `notice_user`.

Лише для **нового** restic-репозиторію виконайте:

```bash
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic init
```

Якщо використовуєте існуючий репозиторій, пропустіть `init` і використовуйте
його пароль. Якщо змінили `restic_password_file` у service-конфігу,
підставте відповідний шлях у команди restic нижче.

### 3.6 Ручне налаштування: перевірка та перший backup

```bash
sudo env RESTIC_PASSWORD_FILE=/etc/system-backup/restic.pass \
  bash backup-system.sh \
  --config "$PWD/configs/backup-config.json" \
  --backup-dir /backup/system/system-backups \
  --dry-run

sudo systemctl start system-backup.service
```

`--print-plan` і `--dry-run` не створюють lock або записів у журналі;
`--dry-run` також перевіряє пароль і доступність репозиторію.
`systemctl start` чекає завершення backup. В іншому терміналі:

```bash
sudo journalctl -u system-backup.service -f
```

Після завершення звірте `status=success` і snapshots:

```bash
sudo tail -n 1 /backup/system/system-backups/backup-history.log
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic snapshots
```

Очікувані теги: `system-root`, `system-boot`, `recovery-metadata`;
при `home.mode=restic` — також `system-home`. Усі snapshots одного запуску
мають спільний `run-<timestamp>`.

### 3.7 Щоденний запуск і подальші перевірки

Після успішного першого backup:

```bash
sudo systemctl enable --now system-backup.timer
systemctl list-timers system-backup.timer --all --no-pager
```

Розклад задається локальним часом у `schedule`. Пропущений запуск не
надолужується (`Persistent=false`). Служба `inactive (dead)` після
успішного завершення — нормальний стан для `Type=oneshot`.

Повна перевірка даних, на додаток до звичайного `restic check`:

```bash
sudo restic --password-file /etc/system-backup/restic.pass \
  -r /backup/system/system-backups/restic check --read-data
```

Перевірка репозиторію не замінює тестового відновлення на інший диск.
Після перегляду повідомлення про попередню помилку приберіть його командою
`scripts/system-backupctl.sh acknowledge`.

### 3.8 Зміна конфігів

Профіль за шляхом `backup_profile` читається при кожному запуску.
Після редагування `backup-config.json` виконайте validate і `--print-plan`.
Без `--config` скрипт використовує вбудований `auto`, навіть якщо локальний
`backup-config.json` існує.

Після редагування локального `service-config.json` застосуйте його явно:

```bash
python3 scripts/service-config.py validate --config configs/service-config.json
sudo bash scripts/install-system-backup.sh --config "$PWD/configs/service-config.json"
systemctl list-timers system-backup.timer --all --no-pager
```

Робоча service-конфігурація — `/etc/system-backup/service.json`. Якщо
редагуєте її безпосередньо, перевстановіть службу без `--config`:

```bash
sudoedit /etc/system-backup/service.json
sudo bash scripts/install-system-backup.sh
```

Інсталяція без `--enable` не вмикає новий таймер; уже увімкнений таймер
залишається увімкненим. Код і файл профілю мають лишатися доступними за
шляхами з service-конфігу.

### Змінні середовища

| Змінна | За замовчуванням | Призначення |
|--------|-------------------|-------------|
| `KEEP_DAILY` | `7` | Скільки денних snapshot'ів лишати при `--prune` |
| `KEEP_WEEKLY` | `4` | Скільки тижневих |
| `KEEP_MONTHLY` | `6` | Скільки місячних |
| `RESTIC_PASSWORD` | — | Пароль репозиторію напряму (небезпечно в unit-файлах, див. §6) |
| `RESTIC_PASSWORD_FILE` | — | Шлях до файлу з паролем (рекомендовано для автономного запуску) |
| `RESTIC_PASSWORD_COMMAND` | — | Команда, що виводить пароль у stdout (інтеграція з менеджером секретів) |

Якщо жодна з трьох `RESTIC_PASSWORD*` змінних не задана — скрипт питає
пароль інтерактивно (`read -rs`), як і раніше. Якщо задана — питання
пропускається повністю (це і є вхідна точка для автономного сервісу).

## 4. Паралельні запуски (lock)

Скрипт бере ексклюзивний `flock -n` на `.backup.lock` перед перевіркою
репозиторію для реального запуску. Якщо лок зайнятий (інший запуск уже триває):

- нічого не робиться, диск не чіпається;
- у `backup-history.log` пишеться рядок `status=skipped
  reason=already_running`;
- скрипт виходить з кодом **0** (це свідомо НЕ помилка — наступний тик
  за розкладом просто спробує знову).

Це страхує від сценарію "cron + ручний запуск одночасно" чи "попередній
прогін ще не встиг завершити restic backup, а таймер уже спрацював
знову".

Якщо живлення зникло під час backup і лишився LVM LV виду
`root-backup-snapshot-YYYYMMDD-HHMMSS`, наступний запуск зупиниться до
створення нового snapshot. Це навмисний захист: такий LV треба спершу
оглянути й прибрати вручну, а не ризикувати автоматично видалити єдину
консистентну копію. Старий LV з іншим іменем скрипт не чіпає.

## 5. Журнал історії запусків (`backup-history.log`)

Простий append-only текстовий формат `key=value`, по одному рядку на
подію — навмисно НЕ JSON, щоб читати без залежностей (`grep`/`awk`/
`cut`), хоча JSON-подібна регулярність (кожен ключ рівно один раз) не
заважає й python-парсингу за потреби.

**Спільні поля в кожному рядку:** `ts` (ISO-8601), `tag` (RUN_TAG цього
прогону, або `-` якщо ще не дійшли до цього кроку), `status`
(`success`/`failed`/`skipped`), `duration_s` (секунди від старту
скрипта), `step` (на якому кроці це сталося — для `failed` це буде
реальне місце падіння).

**Додаткові поля за статусом:**

- `success`: `root_added`, `home_added`, `boot_added`, `meta_added`,
  `total_added` (усі — байти), `root_snapshot`, `home_snapshot`,
  `boot_snapshot`, `meta_snapshot`, `home_mode` і `pruned` (`yes`/`no`).
- `failed`: `exit_code`.
- `skipped`: `reason=already_running`.

Приклади:

```
ts=2026-09-17T06:15:32+03:00 tag=run-20260917-061532 status=success duration_s=142 step=done root_added=47185920 home_added=0 boot_added=2048 meta_added=8192 total_added=47196160 root_snapshot=abcd1234 home_snapshot=- boot_snapshot=ef567890 meta_snapshot=12ab34cd home_mode=auto pruned=no
ts=2026-09-18T03:00:05+03:00 tag=- status=skipped duration_s=0 step=verify_repo reason=already_running
ts=2026-09-19T03:00:12+03:00 tag=run-20260919-030012 status=failed duration_s=18 step=create_snapshot exit_code=1
```

**Кроки (`step`), які можуть з'явитись у `failed`-рядку:** `verify_repo`,
`detect_layout`, `snapshot_sizing`, `restic_password`, `refresh_metadata`,
`create_snapshot`, `backup_root`, `backup_home`, `backup_boot`,
`backup_metadata`, `remove_snapshot`, `prune`, `check_repo`.

Швидкі корисні запити для майбутнього сервісу/моніторингу:

```bash
# Останній рядок узагалі (успіх, невдача чи skip)
tail -1 backup-history.log

# Останній РЕАЛЬНО успішний бекап
grep 'status=success' backup-history.log | tail -1

# Скільки невдач за останній тиждень
awk -v since="$(date -d '7 days ago' -Iseconds)" '$1 > "ts="since' backup-history.log | grep -c 'status=failed'
```

## 6. Автономний запуск через systemd

Робоча служба, таймер, root-only пароль і failure notice вже реалізовані.
Порядок підготовки диска, створення конфігів, ініціалізації restic та
першого запуску наведено в розділі 3. Керування встановленою службою —
у [AUTOMATION.md](AUTOMATION.md).

Timer не надолужує пропущений вечірній запуск (`Persistent=false`), а
`OnFailure=` створює повідомлення для наступної інтерактивної Bash-сесії.
Служба відрізняє очікуваний backup-диск за UUID і не запускає backup у
порожній локальній директорії. Команди контролю та подробиці — у
`AUTOMATION.md` і `CONFIGURATION.md`.

Повна перевірка даних виконується командою `check --read-data` з розділу
3.7; вона не запускається автоматично після кожного backup.

## 7. Розмір і 200 GiB вільного місця на оригінальній системі

Динамічний розрахунок snapshot'у (`min(вільне−1G, 20%×LV)`, мінімум 5G)
свідомо консервативний: снепшоту потрібне місце лише під зміни, зроблені
**під час самого бекапу** (типово хвилини), а не під весь обсяг LV. При
~200 GiB вільного місця у VG формула віддасть щось у районі 20% розміру
LV (десятки, не сотні GiB) — великий запас лишається незайманим. Якщо
колись вільного місця стане критично мало (`< 6G`), скрипт явно впаде з
поясненням, скільки саме бракує, а не мовчки створить замалий снепшот,
який переповниться і зламає консистентність бекапу.
