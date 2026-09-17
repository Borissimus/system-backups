# Відновлення системи

Станом на 2026-09-10 є два способи повернути систему на одному носії
`backup_img`. Вони незалежні за методом відновлення, але **не** є незалежними
копіями: відмова або втрата цього одного зовнішнього диска знищить обидва.
Перед автоматизацією варто мати ще одну перевірену копію на іншому носії або
поза приміщенням.

* **Restic**: `restic/` разом з `recovery-metadata/`. Це основа для
  регулярних інкрементних копій і штатного відновлення.
* **Повний образ диска**: `../nvme0n1-full.img`. Це перевірений fallback для
  найгіршого сценарію: він містить GPT, EFI System Partition, `/boot`, LUKS,
  LVM та кореневу файлову систему в одному побітовому образі.

## Що вже перевірено

`nvme0n1-full.img` має рівно `1024209543168` байт — стільки ж, скільки мав
оригінальний `/dev/nvme0n1`. Файл `../nvme0n1-full.map` має єдиний діапазон
зі статусом `+`, тобто ddrescue завершив читання без непрочитаних секторів.
Збережені хеші образу та початкового диска однакові:

```
7d8b1e36feb478e2750d033bd00d61ad1749799c079b80f5c72763d3a1f872a1
```

Перед реальним відновленням (або під час тесту) повторіть повну перевірку:

```
cd /media/ubuntu/backup_img
sha256sum -c nvme0n1-full.sha256
```

Це прочитає весь образ (~1 ТБ), тому може тривати досить довго. Успішний
результат має бути `nvme0n1-full.img: OK`.

Restic-репозиторій і частина метаданих належать `root`; це нормально для
копії системи, але всі команди Restic у Live USB треба запускати через
`sudo`. Для Restic також обов'язково потрібен пароль репозиторію. Він не
повинен бути лише в пам'яті або лише на втраченому системному диску: збережіть
його в менеджері паролів або іншому окремому безпечному місці.

Повна перевірка Restic, яку слід мати з кодом виходу 0:

```
sudo restic -r /media/ubuntu/backup_img/system-backups/restic snapshots
sudo restic -r /media/ubuntu/backup_img/system-backups/restic check --read-data
```

Цю перевірку виконано 2026-09-10: Restic прочитав усі **5 308** pack-файлів,
завершився з кодом `0` і повідомив `no errors were found`.

У репозиторії є рівно три узгоджені snapshot'и від 2026-09-08:

* `6e73224b` — `system-root`, створений із `/mnt/root-backup-snapshot`;
  перевірено наявність `/etc/fstab`.
* `de4f0264` — `system-boot`, для `/boot` і `/boot/efi`; перевірено GRUB та
  `EFI/ubuntu`.
* `21b8ee39` — `recovery-metadata`; містить усі дев'ять файлів metadata,
  зокрема `nvme0n1.gpt`, `nvme0n1.sfdisk`, LUKS header і `ubuntu-vg.conf`.

Root snapshot створено о 16:37, а boot snapshot — о 18:48, тому вони не є
однією атомарною точкою в часі. Це не проблема, якщо між ними не оновлювалися
ядро, GRUB або LUKS/LVM-конфігурація; практичний тест на чистому SSD остаточно
це підтвердить. Майбутня автоматизація має створювати root, boot і metadata
в межах одного запуску.

Для побітового образу пароль Restic не потрібен, але для першого входу після
завантаження все одно потрібен пароль LUKS.

## Рекомендований тест на чистому SSD: повний образ

1. Завантажтеся з Ubuntu Live USB у режимі UEFI. Підключіть диск із бекапом
   та новий SSD. Не монтуйте розділи нового SSD.
2. Визначте **цільовий** SSD за моделлю, серійним номером і розміром:

   ```
   lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
   sudo blockdev --getsize64 /dev/<TARGET_DISK>
   sudo udevadm info --query=property --name=/dev/<TARGET_DISK> \
     | grep -E 'ID_MODEL=|ID_SERIAL='
   ```

   Ціль повинна бути не меншою за `1024209543168` байт. «1 TB» у назві не
   гарантує достатнього точного числа секторів. Команда наступного кроку
   безповоротно перезаписує саме вказаний диск. Після наступного кроку всі
   дані на цільовому SSD буде знищено.
3. Змонтуйте зовнішній диск з бекапом, наприклад у `/media/ubuntu/backup_img`,
   і (бажано) перевірте хеш образом командою вище.
4. Виконайте копіювання, замінивши `<TARGET_DISK>` на перевірений пристрій
   без номера розділу, наприклад `/dev/nvme0n1`:

   ```
   sudo ddrescue -f \
     /media/ubuntu/backup_img/nvme0n1-full.img \
     /dev/<TARGET_DISK> \
     /media/ubuntu/backup_img/restore-<TARGET_DISK_NAME>.map
   sudo sync
   sudo partprobe /dev/<TARGET_DISK>
   ```

5. Вимкніть Live USB і зовнішній диск, у firmware виберіть новий SSD та
   завантажтеся. Образ відтворює UUID розділів, LUKS і файлових систем, тому
   для SSD того ж або більшого розміру це має бути повне відновлення вмісту
   SSD. UEFI NVRAM boot entries зберігаються у firmware материнської плати,
   а не на SSD, тому сам образ їх не містить.
6. Якщо UEFI не знаходить запис Ubuntu, знову завантажтеся з Live USB,
   відкрийте LUKS та LVM, змонтуйте `/`, `/boot` і ESP, увійдіть у `chroot`
   та перевстановіть GRUB:

   ```
   # Приклад імен розділів: /dev/nvme0n1p1 або /dev/sda1.
   # Нижче вкажіть реальні <TARGET_LUKS>, <TARGET_BOOT> і <TARGET_ESP>.
   sudo cryptsetup open /dev/<TARGET_LUKS> cryptroot
   sudo vgchange -ay
   sudo mount /dev/mapper/ubuntu--vg-ubuntu--lv /mnt
   sudo mount /dev/<TARGET_BOOT> /mnt/boot
   sudo mount /dev/<TARGET_ESP> /mnt/boot/efi
   for i in /dev /dev/pts /proc /sys /run; do sudo mount --bind "$i" "/mnt$i"; done
   sudo chroot /mnt
   grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
   update-grub
   efibootmgr -v
   exit
   ```

   Переконайтеся, що `efibootmgr -v` показує запис Ubuntu. Якщо firmware не
   створює NVRAM entry або не бачить диск, у `chroot` додатково виконайте:

   ```
   grub-install --target=x86_64-efi --efi-directory=/boot/efi \
     --boot-directory=/boot --removable --recheck
   ```

   Це створює стандартний fallback loader `EFI/BOOT/BOOTX64.EFI`. Потім
   розмонтуйте файлові системи та перезавантажте комп'ютер.

## Відновлення через Restic

Restic потрібний для регулярних інкрементних backup, відновлення окремих
файлів і відновлення на диск іншої геометрії. Якщо SSD повністю втрачено, а
цільовий диск не менший за початковий, перевірений `nvme0n1-full.img` є
простішим шляхом. Нижче — file-level recovery через Restic.

### Підготовка Live USB і перевірка цілі

Завантажте Live USB саме в UEFI-режимі та змонтуйте носій backup у
`/media/ubuntu/backup_img`. Якщо в Live USB бракує інструментів і доступна
мережа, встановіть їх:

```
sudo apt update
sudo apt install -y restic lvm2 cryptsetup rsync gdisk dosfstools grub-efi-amd64 efibootmgr
```

Визначте ціль через модель і серійний номер. `DISK` — пристрій без номера
розділу; `ESP`, `BOOT`, `LUKS` — його p1/p2/p3. Для SATA це `/dev/sda1`, для
NVMe — `/dev/nvme0n1p1`.

```
B=/media/ubuntu/backup_img/system-backups
DISK=/dev/<CONFIRMED_TARGET_DISK>
ESP=/dev/<CONFIRMED_TARGET_ESP>
BOOT=/dev/<CONFIRMED_TARGET_BOOT>
LUKS=/dev/<CONFIRMED_TARGET_LUKS>

lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
sudo udevadm info --query=property --name="$DISK" | grep -E 'ID_MODEL=|ID_SERIAL='
```

**Усі наступні команди знищують дані на `$DISK`.** Перед продовженням ще раз
звірте виведений model/serial з цільовим SSD.

### Основний сценарій: SSD такого ж або більшого розміру

1. Відновіть GPT, LUKS header і LVM metadata. Спочатку звірте оригінальний
   PV UUID у двох збережених джерелах, а не копіюйте його з цього документа:

   ```
   sudo cat "$B/recovery-metadata/pvs.txt"
   sudo grep -n -A12 -B2 'physical_volumes' "$B/recovery-metadata/ubuntu-vg.conf"
   # Установіть PVUUID у значення id з секції physical_volumes.
   PVUUID='PASTE_ORIGINAL_PV_UUID_HERE'

   sudo sfdisk "$DISK" < "$B/recovery-metadata/nvme0n1.sfdisk"
   sudo partprobe "$DISK"
   sudo udevadm settle
   sudo cryptsetup luksHeaderRestore "$LUKS" \
     --header-backup-file "$B/recovery-metadata/nvme0n1p3-luks-header.img"
   sudo cryptsetup luksDump "$LUKS"
   sudo cryptsetup open "$LUKS" cryptroot
   sudo pvcreate --uuid "$PVUUID" --restorefile "$B/recovery-metadata/ubuntu-vg.conf" \
     /dev/mapper/cryptroot
   sudo vgcfgrestore -f "$B/recovery-metadata/ubuntu-vg.conf" ubuntu-vg
   sudo vgchange -ay ubuntu-vg
   sudo lvs -a -o lv_name,lv_size,origin,data_percent
   ```

2. За наявності видаліть старий тимчасовий backup snapshot, після чого
   перевірте root LV. До `mkfs` обов'язково має існувати `ubuntu-lv` розміром
   750 GiB:

   ```
   if sudo lvs ubuntu-vg/root-backup-snapshot >/dev/null 2>&1; then
     sudo lvremove -f /dev/ubuntu-vg/root-backup-snapshot
   fi
   sudo lvs -o lv_name,lv_size,vg_name,lv_attr
   sudo blockdev --getsize64 /dev/ubuntu-vg/ubuntu-lv
   ```

### Тестовий сценарій: SSD на 512 GB

Поточний root snapshot має **275.491 GiB** відновлюваних даних, тому 512 GB
SSD достатній для тесту. На ньому **не** використовуйте `nvme0n1.sfdisk`,
`pvcreate --restorefile` або `vgcfgrestore`: вони відтворюють початкову
1 TB схему. Натомість виконайте цей блок замість двох кроків основного
сценарію:

```
sudo sgdisk --zap-all "$DISK"
sudo sgdisk --new=1:0:+1G --typecode=1:ef00 \
  --new=2:0:+2G --typecode=2:8300 \
  --new=3:0:0 --typecode=3:8300 "$DISK"
sudo partprobe "$DISK"
sudo udevadm settle

sudo cryptsetup luksHeaderRestore "$LUKS" \
  --header-backup-file "$B/recovery-metadata/nvme0n1p3-luks-header.img"
sudo cryptsetup luksDump "$LUKS"
sudo cryptsetup open "$LUKS" cryptroot
sudo blockdev --getsize64 /dev/mapper/cryptroot

sudo pvcreate /dev/mapper/cryptroot
sudo vgcreate ubuntu-vg /dev/mapper/cryptroot
sudo lvcreate -L 430G -n ubuntu-lv ubuntu-vg
sudo lvs -o lv_name,lv_size,vg_name,lv_attr
```

`luksDump` і успішне `cryptsetup open` є обов'язковою перевіркою, що
відновлений LUKS2 header працює на меншому backing device. LV на 430 GiB
лишає приблизно 40 GiB вільними у VG для майбутнього LVM snapshot.

### Відновлення файлових систем і boot

Наступні команди спільні для обох сценаріїв. UUID узяті з `blkid.txt`.
Для FAT значення `1571-27FF` записується в `mkfs.fat -i` без дефіса як
`157127FF`.

```
sudo mkfs.fat -F 32 -i 157127FF "$ESP"
sudo mkfs.ext4 -F -U 84152ac4-f388-4b20-b2c2-e396d5d63c48 "$BOOT"
sudo mkfs.ext4 -F -U c2940cae-443b-4d03-8c1e-5a3905765978 \
  /dev/mapper/ubuntu--vg-ubuntu--lv

sudo mkdir -p /mnt/target /mnt/restic-restore
sudo mount /dev/mapper/ubuntu--vg-ubuntu--lv /mnt/target
sudo mkdir -p /mnt/target/boot/efi
sudo mount "$BOOT" /mnt/target/boot
sudo mount "$ESP" /mnt/target/boot/efi

sudo restic -r "$B/restic" snapshots --tag system-root
sudo restic -r "$B/restic" snapshots --tag system-boot
sudo restic -r "$B/restic" restore latest --tag system-root \
  --target /mnt/restic-restore --sparse --verify
sudo rsync -aHAX --numeric-ids /mnt/restic-restore/mnt/root-backup-snapshot/ /mnt/target/
sudo restic -r "$B/restic" restore latest --tag system-boot \
  --target /mnt/restic-restore --sparse --verify
sudo rsync -aHAX --numeric-ids /mnt/restic-restore/boot/ /mnt/target/boot/
```

Перед командами `restore latest` звірте час двох snapshot'ів у виведенні
`snapshots`. Для майбутніх автоматичних backup вони мають походити з одного
запуску; поточні три історичні snapshot'и створювалися в різний час.

У варіанті 512 GB новий LV має інший LVM UUID. Після `rsync` замініть
кореневий рядок у `fstab`; у основному сценарії цього робити **не** треба:

```
sudo sed -i \
  's|^/dev/disk/by-id/dm-uuid-LVM-.* / ext4 |/dev/mapper/ubuntu--vg-ubuntu--lv / ext4 |' \
  /mnt/target/etc/fstab
```

Перед `chroot` перевірте відповідність конфігурації та UUID:

```
sudo cat /mnt/target/etc/fstab
sudo cat /mnt/target/etc/crypttab
sudo blkid "$ESP" "$BOOT" "$LUKS" /dev/mapper/ubuntu--vg-ubuntu--lv
findmnt -R /mnt/target
```

### GRUB, UEFI і завершення

```
for i in /dev /dev/pts /proc /sys /run; do sudo mount --bind "$i" "/mnt/target$i"; done
sudo chroot /mnt/target
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
efibootmgr -v
exit
sudo sync
```

Якщо `efibootmgr -v` не показує Ubuntu або firmware не створює NVRAM entry,
у `chroot` виконайте fallback install:

```
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --boot-directory=/boot --removable --recheck
```

Успішно розмонтуйте відновлену систему, деактивуйте LVM та закрийте LUKS:

```
sudo umount -R /mnt/target
sudo vgchange -an ubuntu-vg
sudo cryptsetup close cryptroot
```

Від'єднайте Live USB і завантажтеся з SSD. Після першого boot перевірте
`findmnt`, `lsblk -f`, `vgs`, `lvs` і запустіть звичайні сервіси системи.
