#!/bin/sh

INSTALL_MODEM=0
FRP_EDIT=0

for arg in "$@"; do
    case "$arg" in
        --modem) INSTALL_MODEM=1 ;;
    esac
    case "$arg" in
        --frp) FRP_EDIT=1 ;;
    esac
done

# BACKUPFILE — первый не-флаг аргумент
BACKUPFILE=""
for arg in "$@"; do
    case "$arg" in
        --*) ;;
        *) BACKUPFILE="$arg"; break ;;
    esac
done


# Проверка и настройка интернета
check_and_fix_internet() {
    echo "=== CHECKING INTERNET CONNECTION ==="

    echo "1. Testing network connectivity..."
    if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        echo "✗ Network connectivity: FAILED"
        echo "   No internet connection available. Package installation will be skipped."
        return 1
    fi
    echo "✓ Network connectivity: OK"

    echo "2. Testing DNS resolution..."
    if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
        echo "✗ DNS: FAILED"
        echo "   Ping works but DNS doesn't - attempting to fix DNS configuration..."

        # Сохраняем старый resolv.conf на случай отката
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null

        # Настраиваем публичные DNS
        cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

        echo "   Waiting for DNS to apply..."
        sleep 2

        echo "3. Re-testing DNS resolution..."
        if ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
            echo "✗ DNS: Still not working after configuration"
            echo "   Package installation will be skipped."
            return 1
        fi

        echo "✓ DNS: FIXED and working"
    else
        echo "✓ DNS: OK"
    fi

    echo "✓ Internet connection: READY"
    return 0
}

# Подготовка системы
prepare_system() {
    echo "=== PREPARING SYSTEM ==="

    echo "1. Cleaning package cache..."
    rm -rf /var/opkg-lists/*

    echo "2. Updating package lists..."
    opkg update

    echo "3. Creating required directories..."
    mkdir -p /etc/uci-defaults
}

# Установка пакета с проверкой
install_package() {
    local package="$1"
    local flags="$2"

    echo -n "Installing: $package ... "

    if opkg list-installed | grep -q "^$package "; then
        echo "✓ (already installed)"
        return 0
    fi

    if opkg install $flags $package >/dev/null 2>&1; then
        echo "✓"
        return 0
    else
        echo "✗"
        return 1
    fi
}

# Установка зависимостей и доп. пакетов
install_dependencies() {
    echo "=== INSTALLING DEPENDENCIES ==="

    for dep in curl jq coreutils-base64 luci-lua-runtime luci-compat luci-lib-ipkg nano wget luci-i18n-base-ru; do
        install_package "$dep"
    done
}

# Восстановление конфигурации
restore_configuration() {
    local backup_file="$1"
    local temp_dir="$2"

    echo "=== RESTORING CONFIGURATION FILES ==="

    echo "Extracting backup files..."
    tar -xzf "$backup_file" -C "$temp_dir"

    echo "Restoring config files..."

    # Список путей для восстановления
    local paths="
        */etc/config/*
        */etc/dropbear/*
        */etc/uhttpd.*
        */etc/opkg/keys/*
        */etc/crontabs/*
        */etc/sing-box/*
        */etc/group
        */etc/passwd
        */etc/shadow
        */etc/hosts
        */etc/shells
        */etc/profile
        */etc/rc.local
        */etc/sysctl.conf
        */etc/inittab
        */etc/shinit
        */etc/nftables.d/*
        */etc/frp/*
        */usr/bin/frpc*
        */etc/init.d/frpc*
    "

    for pattern in $paths; do
        find "$temp_dir" -path "$pattern" -type f 2>/dev/null | while read file; do
            local target_file="${file#$temp_dir}"
            mkdir -p "$(dirname "$target_file")"

            if [ -f "$file" ]; then
                echo "Restoring: $target_file"
                cp "$file" "$target_file"

                # Установка прав доступа
                case "$target_file" in
                    *dropbear*_host_key|*uhttpd.key|*/shadow)
                        chmod 600 "$target_file"
                        ;;
                    *crontabs*)
                        chmod 644 "$target_file"
                        ;;
                esac
            fi
        done
    done
}

# Установка пакетов из списка
install_packages() {
    echo "=== INSTALLING PACKAGES ==="

    local backup_dir="$1"
    local success=0
    local failed=0
    local failed_list=""

    if [ ! -f "$backup_dir/installed_packages.txt" ]; then
        echo "Package list not found"
        return 1
    fi

    while read line; do
        local package=$(echo $line | awk '{print $1}')
        if [ -n "$package" ] && [ "$package" != "Package" ]; then
            if install_package "$package"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
                failed_list="$failed_list\n  - $package"
            fi
        fi
    done < "$backup_dir/installed_packages.txt"

    echo ""
    echo "Successfully installed: $success packages"
    echo "Failed: $failed packages"

    # Вывод списка неустановленных пакетов
    if [ $failed -gt 0 ]; then
        echo ""
        echo "=== FAILED PACKAGES LIST ==="
        echo -e "$failed_list"
    fi
}

# Установка внешнего пакета (универсальная функция)
install_external_package() {
    local name="$1"
    local url="$2"
    local flags="$3"

    echo "=== INSTALLING $name ==="

    local file="/tmp/${name}.ipk"

    echo "Downloading $name..."
    if wget -q -O "$file" "$url"; then
        echo "Installing $name..."
        if opkg install $flags "$file"; then
            echo "✓ $name installed"
            rm -f "$file"
            return 0
        else
            echo "✗ Failed to install $name"
            rm -f "$file"
            return 1
        fi
    else
        echo "✗ Failed to download $name"
        return 1
    fi
}

# Установка Podkop
install_podkop() {
    echo "=== INSTALLING PODKOP ==="

    echo "Downloading Podkop installer..."
    if wget -q -O /tmp/install_podkop.sh "https://raw.githubusercontent.com/itdoginfo/podkop/main/install.sh"; then
        chmod +x /tmp/install_podkop.sh
        echo "Running Podkop installation..."
        /tmp/install_podkop.sh
        rm -f /tmp/install_podkop.sh
    else
        echo "✗ Failed to download Podkop installer"
    fi
}

# Запуск сервисов
start_services() {
    echo "=== STARTING SERVICES ==="

    /etc/init.d/network restart
    /etc/init.d/dropbear restart

    if [ -f "/etc/init.d/podkop" ]; then
        /etc/init.d/podkop enable
        /etc/init.d/podkop start
    fi

    if opkg list-installed | grep -q "sing-box"; then
        /etc/init.d/sing-box enable
        /etc/init.d/sing-box start
    fi

    if [ -f "/etc/init.d/frpc" ]; then
        /etc/init.d/frpc enable
        /etc/init.d/frpc start
    fi

    /etc/init.d/uhttpd restart
}

set_timezone_moscow() {
    echo "=== set timezone Moscow ==="
    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'
    uci commit system
    /etc/init.d/system restart
}

# установка пакетов для поддержки модема
install_modem_stuff() {
    # Пакеты из репозитория opkg
    local pkgs="
        luci-proto-modemmanager
        kmod-usb-serial-wwan
        kmod-usb-serial-option
        kmod-usb-net-cdc-mbim
        usbutils
        kmod-mtd-rw
        kmod-usb2
    "

    for p in $pkgs; do
        install_package "$p" || return 1
    done

    # Пакеты с GitHub (ipk)
    install_external_package "internet-detector" \
        "https://github.com/gSpotx2f/packages-openwrt/blob/master/24.10/internet-detector_1.7.1-r1_all.ipk" \
        "--force-reinstall" || return 1

    install_external_package "internet-detector-mod-modem" \
        "https://github.com/gSpotx2f/packages-openwrt/blob/master/24.10/internet-detector-mod-modem-restart_1.7.1-r1_all.ipk" \
        "--force-reinstall" || return 1

    # enable+start
    if [ -x /etc/init.d/internet-detector ]; then
        /etc/init.d/internet-detector enable
        /etc/init.d/internet-detector start
    else
        service internet-detector enable 2>/dev/null
        service internet-detector start 2>/dev/null
    fi

    install_external_package "luci-app-internet-detector" \
        "https://github.com/gSpotx2f/packages-openwrt/blob/master/24.10/luci-app-internet-detector_1.7.1-r1_all.ipk" \
        "--force-reinstall" || return 1

    service rpcd restart 2>/dev/null || /etc/init.d/rpcd restart

    install_external_package "luci-i18n-internet-detector-ru" \
        "https://github.com/gSpotx2f/packages-openwrt/blob/master/24.10/luci-i18n-internet-detector-ru_1.7.1-r1_all.ipk" \
        "--force-reinstall" || return 1

    return 0
}

# редактировать конфиг FRPC если вызван аргумент --frp
edit_frp_number() {
    printf "FRP: configure number"

    # спросить N (две цифры)
    while :; do
        printf "Enter FRP number N (00-99): "
        read -r FRP_N
        case "$FRP_N" in
            [0-9]|[0-9][0-9])
                FRP_N=$(printf "%02d" "$FRP_N" 2>/dev/null || echo "$FRP_N")
                break
                ;;
            *)
                echo "Invalid N, expected 0..99"
                ;;
        esac
    done

    if [ ! -f /etc/frp/frpc.toml ]; then
        echo "WARNING: /etc/frp/frpc.toml not found, skipping"
        return 0
    fi

    sed -i -E \
      -e 's/\bopenwrt-web-[0-9]{2}\b/openwrt-web-'"$FRP_N"'/g' \
      -e 's/\brouter[0-9]{2}\b/router'"$FRP_N"'/g' \
      -e 's/\bopenwrt-ssh-[0-9]{2}\b/openwrt-ssh-'"$FRP_N"'/g' \
      -e 's/\bremotePort = 610[0-9]{2}\b/remotePort = 610'"$FRP_N"'/' \
      /etc/frp/frpc.toml

    [ -x /etc/init.d/frpc ] && /etc/init.d/frpc stop && /etc/init.d/frpc start
    # чтение лога frpc
    tail /var/log/frpc.log

}



# Финальный отчет
print_status() {
    echo ""
    echo "=== RESTORE COMPLETED ==="
    echo "Podkop: $( [ -f "/etc/init.d/podkop" ] && echo "✓" || echo "✗" )"
    echo "FRPC $( [ -f "/etc/init.d/frpc" ] && echo "✓" || echo "✗" )"
    echo "sing-box: $(opkg list-installed | grep -q "sing-box" && echo "✓" || echo "✗")"
    echo ""
    echo "System ready. Reboot if needed: reboot"
}

# ========== ОСНОВНОЙ СКРИПТ ==========

BACKUP_DIR="/root/backup"
BACKUP_FILE="$1"

# Проверка аргументов
if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    echo "Available backups:"
    ls -la $BACKUP_DIR/*.tar.gz 2>/dev/null || echo "No backups found"
    exit 1
fi

# Проверка существования файла
if [ ! -f "$BACKUP_FILE" ]; then
    BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
fi

# Предупреждение
echo "Smart restore from: $BACKUP_FILE"
echo "=== WARNING: This will overwrite existing configuration files! ==="
echo "Press Ctrl+C to cancel or Enter to continue..."
read

# Создание временной директории
TEMP_DIR="/tmp/restore_$"
mkdir -p $TEMP_DIR

# Проверка интернета перед началом установки
if ! check_and_fix_internet; then
    echo ""
    echo "=== WARNING: No internet connection ==="
    echo "Package installation will be skipped."
    echo "Only configuration files will be restored."
    echo ""
    echo "Press Ctrl+C to cancel or Enter to continue with config restore only..."
    read

    # Только восстановление конфигурации без установки пакетов
    restore_configuration "$BACKUP_FILE" "$TEMP_DIR"
    start_services
    print_status
    rm -rf $TEMP_DIR
    exit 0
fi

# перезапустим NTP сервер для исключения ошибок авторизации
/etc/init.d/sysntpd restart && sleep 3

# Установка пакетов (каждая функция обработает ошибки сама)
prepare_system

if [ "$INSTALL_MODEM" -eq 1 ]; then
    install_modem_stuff || echo "WARNING: modem install failed"
fi

install_dependencies
install_packages "$BACKUP_DIR"
install_podkop

# Восстановление конфигурации (всегда)
restore_configuration "$BACKUP_FILE" "$TEMP_DIR"

# редактирование номер frpc если передан аргумент --frp
if [ "$FRP_EDIT" -eq 1 ]; then
    edit_frp_number
fi

# Запуск сервисов (всегда)
start_services

set_timezone_moscow

# Отчет и очистка
print_status
rm -rf $TEMP_DIR
