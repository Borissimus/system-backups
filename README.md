# system-backups — резервне копіювання та відновлення

Цей каталог — самодостатній комплект для backup системи через
[restic](https://restic.net/). `backup-system.sh` підтримує LVM-on-LUKS і
простіші root-схеми; для поточного, перевіреного LVM-on-LUKS UEFI профілю є
повна процедура recovery в `RECOVERY.md`. Налаштування іншої машини,
окремого `/home` і служби описані в `CONFIGURATION.md`.

## Зміст каталогу

| Файл/каталог              | Призначення |
|----------------------------|-------------|
| `restic/`                  | Сам restic-репозиторій (зашифрований, content-addressed) |
| `recovery-metadata/`       | GPT/LUKS-заголовок/LVM-конфіг оригінального диска — оновлюється щобекапу |
| `backup-system.sh`         | Створення нового бекапу (цей документ) |
| `restore-system.sh`        | Повне відновлення на новий диск |
| `backup-config.example.json` | Приклад profile root/LUKS/boot/home для конкретної машини |
| `service-config.example.json` | Приклад JSON-параметрів systemd-служби без секретів |
| `backup-history.log`       | Журнал історії запусків `backup-system.sh` (створюється автоматично) |
| `.backup.lock`             | Lock-файл проти паралельних запусків (створюється автоматично) |
| `.restore-progress` / `.restore-cache` | Службові файли `restore-system.sh` (resume/кеш) |

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

Це була вихідна вимога, тому пояснюю механізм явно (щоб майбутній сервіс
на цьому будувався свідомо, а не "на довірі"):

- **restic — content-addressed сховище.** Кожен шматок даних (chunk)
  зберігається один раз за хешем вмісту, незалежно від того, з якого
  файлу/snapshot'у він прийшов. Навіть якщо parent snapshot не знайдено
  (див. нижче), уже наявний за хешем блок ніколи не заливається вдруге.
- **Автоматичний parent snapshot.** `restic backup <шлях>` сам шукає
  останній snapshot з тим самим (hostname, шлях) і використовує його як
  базу для швидкого визначення змінених файлів (за mtime+size, без
  повного перечитування вмісту незмінених файлів). Шлях кореня
  (`/mnt/root-backup-snapshot`) — **той самий**, що використовувався і в
  оригінальному ручному бекапі 2026-09-08 (див. `restore-system.sh`:
  rsync бере `.../mnt/root-backup-snapshot/`), тому нові прогони
  автоматично продовжують той самий ланцюжок snapshot'ів, а не
  починають окрему лінію.
- **LVM-снепшот — не повна копія.** Це лише copy-on-write шар для
  консистентності на час бекапу (кілька хвилин); сам знімок займає лише
  стільки місця, скільки даних змінилося ПІД ЧАС бекапу (звідси й
  динамічний розрахунок розміру, а не фіксовані сотні гігабайт).

Отже "інкрементність" — це не окрема логіка, яку треба було дописати, а
природний наслідок правильного використання restic. Єдине, що дійсно
було потрібно виправити (і вже виправлено) — два реальні баги у
визначенні VG/LV/диска, через які скрипт узагалі не доходив би до
restic-кроку на реальній системі (див. `CLAUDE-SESSION-NOTES.md`).

## 3. Використання

```bash
sudo bash backup-system.sh --config backup-config.json --print-plan  # без пароля й записів
sudo bash backup-system.sh --config backup-config.json --dry-run     # перевірити repo/пароль, без backup
sudo bash backup-system.sh --config backup-config.json               # реальний backup
sudo bash backup-system.sh --config backup-config.json --prune       # backup + retention
```

Якщо `--config` не передано, використовується вбудований безпечний профіль
`auto`. Значення й обмеження всіх режимів — у `CONFIGURATION.md`.

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

Скрипт бере ексклюзивний `flock -n` на `.backup.lock` **одразу після**
перевірки репозиторію. Якщо лок зайнятий (інший запуск уже триває):

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
На новій машині дійте в такому порядку:

1. Змонтуйте backup-диск через `/etc/fstab` за UUID з `nofail` (приклад у
   `AUTOMATION.md`) і переконайтеся, що каталог репозиторію доступний.
2. За потреби налаштуйте `backup-config.json` для topology root/LUKS/`/home`.
   Перед інсталяцією можна також підготувати `service-config.json`; інакше
   installer виявить mount та UUID сам.
3. Запустіть `scripts/system-backupctl.sh install`. Він встановить служби,
   створить/збереже root-only файл пароля і залишить timer вимкненим.
4. Перевірте один запуск: `scripts/system-backupctl.sh run`, потім
   `scripts/system-backupctl.sh logs`.
5. Лише після успіху виконайте `scripts/system-backupctl.sh enable`.

Timer не надолужує пропущений вечірній запуск (`Persistent=false`), а
`OnFailure=` створює повідомлення для наступної інтерактивної Bash-сесії.
Служба відрізняє очікуваний backup-диск за UUID і не запускає backup у
порожній локальній директорії. Команди контролю та подробиці — у
`AUTOMATION.md` і `CONFIGURATION.md`.

Раз на місяць доцільно вручну виконати
`sudo restic -r ./restic check --read-data`: звичайний запуск робить швидкий
`restic check` без повного читання даних.

## 7. Розмір і 200 GiB вільного місця на оригінальній системі

Динамічний розрахунок snapshot'у (`min(вільне−1G, 20%×LV)`, мінімум 5G)
свідомо консервативний: снепшоту потрібне місце лише під зміни, зроблені
**під час самого бекапу** (типово хвилини), а не під весь обсяг LV. При
~200 GiB вільного місця у VG формула віддасть щось у районі 20% розміру
LV (десятки, не сотні GiB) — великий запас лишається незайманим. Якщо
колись вільного місця стане критично мало (`< 6G`), скрипт явно впаде з
поясненням, скільки саме бракує, а не мовчки створить замалий снепшот,
який переповниться і зламає консистентність бекапу.
