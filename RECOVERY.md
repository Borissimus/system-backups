# Відновлення системи з restic

Це інструкція до `restore-system.sh`. Поточна реалізація відновлює
**Ubuntu x86_64, UEFI, root ext4 на LVM усередині LUKS, окремий ext4 `/boot`
та FAT32 EFI**. Відновлення виконується на явно вибраний цілий диск,
усі дані якого буде стерто після підтвердження.

Стан реалізації: 2026-10-09 успішно відновлено бекап
`run-20261008-230002` на PLEXTOR PX-256M6S+ 256 GB із працюючої Ubuntu.
Після від’єднання оригінального системного диска відновлена ОС завантажилась:
root на новому LUKS/LVM, boot/EFI на PLEXTOR, зовнішній home підключений;
failed units немає, backup timer disabled/inactive. Перевірений режим:
усі identifiers generate, luks_header new, dracut, Secure Boot вимкнений.
Відновлення з Live USB, original identifiers та старий LUKS header ще
не перевірені фізично. Перед кожним restore виконайте dry-run і звірте план.

## Де виконувати

Можна підготувати новий диск із поточної Ubuntu, залишивши оригінальну
систему працювати, якщо вибрані UUID і назви VG/mapping не конфліктують.
Альтернатива — Ubuntu Live USB. Для першого завантаження з відновленого
диска рекомендовано від'єднати оригінальний системний диск; окремий
`/home`, якщо він потрібний відновленій ОС, залишити підключеним.

Restore не використовує host mount `/mnt/root-backup-snapshot`, не
деактивує чужі VG та не прибирає чужі mappings. Зайнятий цільовий диск
(будь-який mount, swap або активний storage mapping) відхиляється.
GRUB встановлюється тільки на ESP цільового диска з `--no-nvram` та
fallback loader `EFI/BOOT/BOOTX64.EFI`; записи й порядок завантаження
поточної firmware не змінюються. Для першого тесту Secure Boot має бути
вимкнений; реалізація відхиляє host зі встановленим прапорцем Secure Boot.

## Що підготувати

- Підключений диск із restic-репозиторієм, змонтований, наприклад, у
  `/backup/system`; storage-каталог — `/backup/system/system-backups`.
- Код цього проєкту, доступний також із Live USB, якщо обраний цей спосіб.
- Пароль restic: він потрібний окремо від зашифрованого репозиторію.
- Новий диск та його точний serial. Розмір може відрізнятися від джерела:
  план перевіряє обсяг даних, boot-розділи, filesystem overhead і резерв VG.

Залежності host (скрипт не встановлює пакети автоматично):

```bash
sudo apt update
sudo apt install python3 restic lvm2 cryptsetup gdisk dosfstools util-linux
```

У відновленій Ubuntu мають бути dracut або `initramfs-tools` із
`cryptsetup-initramfs`, а також GRUB EFI; скрипт виконує їх через chroot після копіювання.

Перевірте диски й сховище:

```bash
lsblk -o NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
ls -l /dev/disk/by-id/
findmnt --mountpoint /backup/system
```

## Створення restore-конфігу

Backup-конфіг описує вихідну систему. Ціль, її ідентифікатори й спосіб
створення LUKS задаються **окремим** restore-конфігом у `configs/`, поза Git.
Детальний приклад: [configs/restore-config.example.jsonc](configs/restore-config.example.jsonc).
Підтримуються JSON та `//` коментарі на окремих рядках.

Інтерактивний майстер лише створює конфіг, не змінює диски:

```bash
sudo bash restore-system.sh --interactive \
  --backup-dir /backup/system/system-backups \
  --config "$PWD/configs/restore-config.json"
```

Він показує незмонтовані цілі, просить вибір диска, режим ідентифікаторів,
спосіб роботи з LUKS header, host/run бекапу та шлях до password-файлу.
Serial вибраного диска записується в конфіг. Наявний конфіг не перезаписується.
Оскільки майстер запущений із sudo, файл буде root-owned із mode 0600.
Редагуйте його через `sudoedit`.

Або скопіюйте й заповніть приклад вручну:

```bash
cp configs/restore-config.example.jsonc configs/restore-config.jsonc
nano configs/restore-config.jsonc
python3 scripts/restore-config.py validate --config configs/restore-config.jsonc
```

Обов'язково задайте `target.device` і точний `target.serial`. Бажано
використовувати стабільний `/dev/disk/by-id/...`, що посилається на
**диск**, а не `...-part1`. На кожному запуску перевіряються serial,
тип пристрою, розмір, WWN та відсутність використання цілі системою.

## Ідентифікатори

Для кожного поля `identifiers` допустимі:

| Значення | Поведінка |
|----------|-----------|
| `original` | Взяти значення з metadata вибраного backup-run; це default |
| `generate` | Згенерувати нове значення й зафіксувати його в журналі restore |
| Власне значення | Використати його після перевірки формату та конфліктів |

Поля: UUID LUKS, root, boot та EFI, назви VG, LV і відкритого LUKS mapping.
EFI UUID — FAT volume ID виду `A1B2-C3D4`, а не 128-бітний UUID.
UUID PV/VG/LV усередині LVM створюються свіжими самим LVM; поля `vg_name`
та `lv_name` керують назвами, не внутрішніми LVM UUID.

**Для відновлення поруч із поточною системою виберіть `generate` для всіх
полів.** LV може мати стару назву в іншій VG, але нова назва теж підтримується.
Режим `original` призначений для заміни, коли оригінальний диск від'єднаний.
Скрипт не ігнорує конфлікти: UUID перевіряються на всіх видимих block devices,
включно незмонтованими, VG — через LVM, mapping — також через `/dev/mapper`.
Ідентифікатори всередині закритого стороннього LUKS контейнера недоступні;
якщо оригінальний LUKS-диск підключений, його стару VG не дозволено повторно
використовувати навіть коли вона прихована за закритим контейнером.

## Паролі та LUKS header

Пароль restic відкриває сховище. Задайте `restic_password_file` або лишіть
порожній рядок для запиту; нативні `RESTIC_PASSWORD*` теж підтримуються.
Паролі не записуються в restore-конфіг чи журнал.

`luks_header`:

- `new` (default): створити новий LUKS2 контейнер із запитаним новим паролем;
- `restore`: використати header зі snapshot metadata, зберігши оригінальні
  ключі й пароль. Це вибір користувача, а не обов'язкова умова file restore.

В обох режимах target LUKS UUID визначається полем `identifiers.luks_uuid`.
Після створення/restoring header скрипт знову попросить LUKS пароль для
відкриття контейнера. Для `restore` потрібен старий пароль джерела.

## Dry-run і вибір бекапу

```bash
sudo bash restore-system.sh \
  --config "$PWD/configs/restore-config.json" --dry-run
```

Для вручну заповненого JSONC підставте `configs/restore-config.jsonc`.
Dry-run читає сховище, тимчасово витягує metadata й перевіряє план;
**цільовий диск не змінюється**, журнал restore не створюється.
На час перевірки/відновлення береться `.backup.lock`, щоб локальна
backup-служба не працювала одночасно. Не запускайте prune із інших
машин під час відновлення.

`backup_run=latest` вибирає останній **повний узгоджений запуск**, де є
рівно по одному root, boot і metadata snapshot із тим самим host/run тегом.
Незавершений новіший запуск пропускається; незалежні «latest root» і
«latest boot» не змішуються. Для кількох hosts обов'язково задайте
`backup_host`. Для точного запуску задайте `run-YYYYMMDD-HHMMSS`.

Metadata, включно backup/service конфігами, читаються **зі snapshot**
цього запуску, а не з локального змінюваного `recovery-metadata/`.
Старі snapshots без archived конфігів можуть працювати, якщо `layout.json`
містить потрібну топологію, UUID та поля filesystem. Старий бекап без
`layout.json` новий restore не підтримує.

План показує точні snapshot IDs, ціль/serial/WWN/розмір, resolved UUID і
назви, обсяг root та стан окремого `/home`. Переконайтеся, що ціль — новий
диск, а не root, home, swap чи backup-диск.

## Запуск

Після успішного dry-run:

```bash
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json"
```

Перед змінами потрібно ввести **`ERASE <serial>`**. Після цього ідентичність
диска й конфлікти перевіряються повторно. Операції:

1. Нова GPT: ESP 1 GiB, `/boot` 2 GiB, LUKS — решта диска.
2. LUKS, PV/VG і root LV; default LV займає 90% вільного VG.
3. FAT32 ESP, ext4 boot/root із вибраними UUID.
4. Відновлення конкретних root/boot snapshots через restic з `--verify`.
   Subfolder restore пише прямо на ціль, без подвійної копії root.
5. Заміна root/boot/EFI записів у target `fstab`, формування target `crypttab`
   із `luks,initramfs`, оновлення явних kernel/EFI config посилань.
   Зовнішні `/home`/swap mounts зберігаються; їхні пристрої потрібні окремо.
6. Прибирання старих LVM devices/cache прив'язок і resume налаштувань.
7. Regenerate initramfs із перевіркою embedded cryptroot UUID, GRUB на
   target ESP без NVRAM змін; os-prober вимкнений у відновленій ОС.
8. Розмонтування тільки створених цим запуском mounts, деактивація тільки
   target VG та закриття тільки target mapping.

Backup timer **у відновленій ОС** лишається вимкненим. Після її першого
завантаження звірте service/backup конфіги й виконайте setup окремо.
Таймер поточної host ОС скрипт не переналаштовує; запуск backup під час
restore пропускається через lock.

## Журнал і продовження

Журнал — `<backup_dir>/.restore-state.json`, mode 0600. Він прив'язаний до
hash restore-конфігу, disk identity, точних snapshot IDs і resolved
ідентифікаторів. Згенеровані UUID під час resume не змінюються.

```bash
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --status
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --resume --dry-run
sudo bash restore-system.sh --config "$PWD/configs/restore-config.json" --resume
```

Після збою повторюйте з `--resume`, не звичайним запуском. Завершені
partition/LUKS/LVM/filesystem кроки перевіряються; невідповідність зупиняє
restore, не викликає повторне стирання. Файловий крок, який не встиг
завершитися, виконується знову на вже підготовленій цілі.
Після SIGKILL чи вимкнення живлення mappings/mounts можуть залишитися;
їх треба оглянути й закрити вручну. Скрипт не робить force teardown.

Для іншої цілі або нового restore-конфігу архівуйте старий журнал вручну
лише після огляду диска. Автоматичного `--reset` зі стиранням немає.

## Перший реальний тест

1. Підключіть новий диск; звірте model/serial/size.
2. Створіть конфіг із `generate` для всіх identifiers, `luks_header=new`.
3. Виконайте dry-run; надішліть план для перевірки перед запуском.
4. Виконайте restore й перевірте фінальний стан та cleanup.
5. Вимкніть машину, від'єднайте оригінальний системний диск, завантажтеся
   з нового через firmware boot menu. Зовнішній `/home` лишіть підключеним.
6. Перевірте LUKS prompt, boot, login, `findmnt`, `lsblk -f`, `vgs`,
   `journalctl -b -p err`. Лише це підтвердить end-to-end recovery.

Окремий `/home`, навіть коли snapshot `system-home` є в тому самому repo,
інші LV та інші окремі filesystems цей механізм не відновлює. Їх відновлення
потребує окремої цілі/процедури. Secure Boot, TPM unlock, RAID і інші
root layouts цим restore не підтримуються.

### Initramfs із dracut

Для Ubuntu із dracut restore створює generic initramfs без host-only
command line працюючої ОС, включає crypt/LVM і target crypttab, задає
цільові rd.luks.uuid та rd.lvm.lv для GRUB. Перевірка UUID підтримує
обидва layouts: dracut etc/crypttab та initramfs-tools cryptroot/crypttab.
Після помилки на bootloader-кроці продовжуйте тим самим конфігом через
`--resume`: завершені partition/format/root/boot кроки не повторюються.
