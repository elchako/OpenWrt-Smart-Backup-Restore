#!/bin/sh

# Директория для бэкапа
BACKUP_DIR="/root/backup"
mkdir -p $BACKUP_DIR
BACKUP_FILE="openwrt_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

echo "=== CREATING SMART BACKUP ==="
echo ""

# Функция для добавления файлов в список бэкапа
add_files() {
    local description="$1"
    local files="$2"
    local count=0
    
    if [ -n "$files" ]; then
        echo "=== $description ==="
        for file in $files; do
            if [ -f "$file" ]; then
                FILES_TO_BACKUP="$FILES_TO_BACKUP $file"
                echo "  ✓ $file"
                count=$((count + 1))
            fi
        done
        [ $count -eq 0 ] && echo "  (none found)"
        echo ""
    fi
}

# Инициализация списка файлов
FILES_TO_BACKUP=""

# 1. Измененные конфиг-файлы через opkg
MODIFIED_CONFIGS=$(opkg list-changed-conffiles 2>/dev/null)
add_files "Modified Config Files" "$MODIFIED_CONFIGS"

# 2. Все файлы в /etc/config/
ALL_CONFIGS=$(find /etc/config/ -type f 2>/dev/null)
add_files "All Config Files" "$ALL_CONFIGS"

# 3. SSH ключи
SSH_KEYS=$(find /etc/dropbear/ -name "dropbear_*_host_key" -type f 2>/dev/null)
add_files "SSH Host Keys" "$SSH_KEYS"

# 4. SSL сертификаты uhttpd
UHTTPD_CERTS=$(find /etc/ -name "uhttpd.*" -type f 2>/dev/null)
add_files "uHTTPd Certificates" "$UHTTPD_CERTS"

# 5. Ключи opkg
OPKG_KEYS=$(find /etc/opkg/keys/ -type f 2>/dev/null)
add_files "OPKG Keys" "$OPKG_KEYS"

# 6. Пользовательские crontabs
CRONTABS=$(find /etc/crontabs/ -type f 2>/dev/null)
add_files "Crontabs" "$CRONTABS"

# 7. Конфиги sing-box
SING_BOX_CONFIGS=$(find /etc/sing-box/ -name "*.json" -type f 2>/dev/null)
add_files "Sing-box Configs" "$SING_BOX_CONFIGS"

# 8. Важные системные файлы
SYSTEM_FILES="
/etc/group
/etc/passwd
/etc/shadow
/etc/hosts
/etc/shells
/etc/profile
/etc/rc.local
/etc/sysctl.conf
/etc/inittab
/etc/shinit
"
add_files "System Files" "$SYSTEM_FILES"

# 9. Пользовательские nftables правила
NFTABLES_RULES=$(find /etc/nftables.d/ -name "*.nft" -type f 2>/dev/null)
add_files "NFTables Rules" "$NFTABLES_RULES"

# Создаем архив
echo "=== CREATING ARCHIVE ==="
echo "File: $BACKUP_DIR/$BACKUP_FILE"

if tar -czf $BACKUP_DIR/$BACKUP_FILE $FILES_TO_BACKUP 2>/dev/null; then
    echo "✓ Archive created successfully"
else
    echo "✗ Failed to create archive"
    exit 1
fi

# Создаем список установленных пакетов
echo ""
echo "=== SAVING PACKAGE LIST ==="
if opkg list-installed > $BACKUP_DIR/installed_packages.txt; then
    echo "✓ Package list saved: $BACKUP_DIR/installed_packages.txt"
    echo "  Total packages: $(wc -l < $BACKUP_DIR/installed_packages.txt)"
else
    echo "✗ Failed to save package list"
fi

# Итоговая информация
echo ""
echo "=== BACKUP COMPLETED ==="
echo "Backup file: $BACKUP_DIR/$BACKUP_FILE"
echo "Total files backed up: $(echo $FILES_TO_BACKUP | wc -w)"
echo "Backup size: $(du -h $BACKUP_DIR/$BACKUP_FILE | cut -f1)"
echo ""
echo "To restore, use: smart_restore.sh $BACKUP_FILE"
