#!/bin/bash
# Включаем строгий режим для безопасности
set -euo pipefail

# ==========================================
# ДЕФОЛТНЫЕ ЗНАЧЕНИЯ (Настройки по умолчанию)
# ==========================================
TARGET_DIR="./mock_data"
FILE_COUNT=200
DATE_START="2023-01-01"
DATE_END="2024-01-01"
SIZE_MIN=1  # Минимальный размер (в Мегабайтах)
SIZE_MAX=5  # Максимальный размер (в Мегабайтах)
USE_FOLDERS=0
MAX_DEPTH=3
DATE_TARGET="modify" # По умолчанию меняем только дату изменения (mtime)

# ==========================================
# ПАРСИНГ ФЛАГОВ ИЗ КОМАНДНОЙ СТРОКИ
# ==========================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--count) FILE_COUNT="$2"; shift ;;
        -ds|--date-start) DATE_START="$2"; shift ;;
        -de|--date-end) DATE_END="$2"; shift ;;
        -dc|--date-create) DATE_TARGET="create" ;;
        -sm|--size-min) SIZE_MIN="$2"; shift ;;
        -sx|--size-max) SIZE_MAX="$2"; shift ;;
        -f|--folders) USE_FOLDERS=1 ;;
        -d|--depth) MAX_DEPTH="$2"; shift ;;
        -t|--target) TARGET_DIR="$2"; shift ;;
        -h|--help) 
            echo "Использование: $0 [опции]"
            echo "Опции:"
            echo "  -c,  --count      Количество файлов (дефолт: $FILE_COUNT)"
            echo "  -ds, --date-start Начальная дата YYYY-MM-DD (дефолт: $DATE_START)"
            echo "  -de, --date-end   Конечная дата YYYY-MM-DD (дефолт: $DATE_END)"
            echo "  -dc, --date-create Включить 'Машину времени' (нужен root). Меняет реальный btime."
            echo "  -sm, --size-min   Мин. размер файла в МБ (дефолт: $SIZE_MIN)"
            echo "  -sx, --size-max   Макс. размер файла в МБ (дефолт: $SIZE_MAX)"
            echo "  -f,  --folders    Включить генерацию вложенных папок"
            echo "  -d,  --depth      Максимальная глубина папок (дефолт: $MAX_DEPTH)"
            echo "  -t,  --target     Целевая директория (дефолт: $TARGET_DIR)"
            exit 0
            ;;
        *) echo "Неизвестный параметр: $1. Используйте -h для справки."; exit 1 ;;
    esac
    shift
done

# ==========================================
# ПОДГОТОВКА И ЛОГИКА
# ==========================================

# Защита и настройка Машины времени
if [[ "$DATE_TARGET" == "create" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo -e "\e[31mОшибка: Для хардкорной подмены даты создания (-dc) требуются права root (sudo)!\e[0m"
        exit 1
    fi
    echo -e "\e[33mВНИМАНИЕ: Активирована Машина времени. Отключаем NTP...\e[0m"
    # Железобетонный возврат времени при любом исходе
    trap 'echo -e "\n\e[33mВозвращаем время в норму (NTP)...\e[0m"; timedatectl set-ntp true; sleep 2; echo -e "\e[32mТекущее время восстановлено: $(date)\e[0m"' EXIT INT TERM ERR
    timedatectl set-ntp false
fi

# Переводим даты в UNIX timestamp
START_TS=$(date -d "$DATE_START" +%s)
END_TS=$(date -d "$DATE_END" +%s)
DIFF=$((END_TS - START_TS))

if [ "$DIFF" -lt 0 ]; then
    echo "Ошибка: Конечная дата должна быть больше начальной!"
    exit 1
fi

mkdir -p "$TARGET_DIR"
echo "Начинаем генерацию $FILE_COUNT файлов в '$TARGET_DIR'..."

for (( i=1; i<=FILE_COUNT; i++ )); do
    # 1. Генерируем случайный размер и дату
    RAND_SIZE=$(shuf -i $SIZE_MIN-$SIZE_MAX -n 1)
    RAND_ADD=$(shuf -i 0-$DIFF -n 1)
    RAND_TS=$((START_TS + RAND_ADD))
    RAND_DATE=$(date -d "@$RAND_TS" +"%Y-%m-%d %H:%M:%S")
    
    # 2. Логика вложенных папок
    CURRENT_DIR="$TARGET_DIR"
    if [ "$USE_FOLDERS" -eq 1 ]; then
        DEPTH=$(shuf -i 1-$MAX_DEPTH -n 1)
        for (( j=1; j<=DEPTH; j++ )); do
            DIR_NAME="dir_$(shuf -i 1-5 -n 1)"
            CURRENT_DIR="$CURRENT_DIR/$DIR_NAME"
        done
        mkdir -p "$CURRENT_DIR"
    fi
    
    # 3. Подготовка пути (имя файла генерим ДО прыжка во времени, чтобы избежать путаницы в названиях)
    FILE_PATH="$CURRENT_DIR/file_$(date -d "@$RAND_TS" +%s)_${i}.log"
    
    # 4. ПРИМЕНЕНИЕ ДАТЫ И СОЗДАНИЕ ФАЙЛА
    if [[ "$DATE_TARGET" == "create" ]]; then
        # Прыгаем в прошлое/будущее
        date -s "$RAND_DATE" > /dev/null
        # Создаем файл (ФС зашивает ему текущее "фейковое" системное время как btime, mtime и atime)
        fallocate -l "${RAND_SIZE}M" "$FILE_PATH" 2>/dev/null || dd if=/dev/zero of="$FILE_PATH" bs=1M count="$RAND_SIZE" status=none
    else
        # Обычный режим: просто создаем файл в настоящем времени
        fallocate -l "${RAND_SIZE}M" "$FILE_PATH" 2>/dev/null || dd if=/dev/zero of="$FILE_PATH" bs=1M count="$RAND_SIZE" status=none
        # И подменяем только дату модификации
        touch -m -d "$RAND_DATE" "$FILE_PATH"
    fi
    
    # Выводим прогресс
    if (( i % 100 == 0 )); then
        echo "Сгенерировано $i из $FILE_COUNT файлов..."
    fi
done

echo "=== Готово! ==="
echo "Папка назначения: $TARGET_DIR"
echo "Объем сгенерированных данных: $(du -sh "$TARGET_DIR" | awk '{print $1}')"

# При запуске с -dc здесь автоматически сработает trap и вернет NTP