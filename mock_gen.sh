#!/bin/bash

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

# ==========================================
# ПАРСИНГ ФЛАГОВ ИЗ КОМАНДНОЙ СТРОКИ
# ==========================================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--count) FILE_COUNT="$2"; shift ;;
        -ds|--date-start) DATE_START="$2"; shift ;;
        -de|--date-end) DATE_END="$2"; shift ;;
        -sm|--size-min) SIZE_MIN="$2"; shift ;;
        -sx|--size-max) SIZE_MAX="$2"; shift ;;
        -f|--folders) USE_FOLDERS=1 ;;
        -d|--depth) MAX_DEPTH="$2"; shift ;;
        -t|--target) TARGET_DIR="$2"; shift ;;
        -h|--help) 
            echo "Использование: $0 [опции]"
            echo "Опции:"
            echo "  -c,  --count       Количество файлов (дефолт: 200)"
            echo "  -ds, --date-start  Начальная дата YYYY-MM-DD (дефолт: $DATE_START)"
            echo "  -de, --date-end    Конечная дата YYYY-MM-DD (дефолт: $DATE_END)"
            echo "  -sm, --size-min    Мин. размер файла в МБ (дефолт: $SIZE_MIN)"
            echo "  -sx, --size-max    Макс. размер файла в МБ (дефолт: $SIZE_MAX)"
            echo "  -f,  --folders     Включить генерацию вложенных папок"
            echo "  -d,  --depth       Максимальная глубина папок (дефолт: $MAX_DEPTH)"
            echo "  -t,  --target      Целевая директория (дефолт: $TARGET_DIR)"
            exit 0
            ;;
        *) echo "Неизвестный параметр: $1. Используйте -h для справки."; exit 1 ;;
    esac
    shift
done

# ==========================================
# ПОДГОТОВКА И ЛОГИКА
# ==========================================
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
    # 1. Генерируем случайный размер
    # Используем shuf для лучшего рандома
    RAND_SIZE=$(shuf -i $SIZE_MIN-$SIZE_MAX -n 1)
    
    # 2. Генерируем случайную дату
    RAND_ADD=$(shuf -i 0-$DIFF -n 1)
    RAND_TS=$((START_TS + RAND_ADD))
    RAND_DATE=$(date -d "@$RAND_TS" +"%Y-%m-%d %H:%M:%S")
    
    # 3. Логика вложенных папок
    CURRENT_DIR="$TARGET_DIR"
    if [ "$USE_FOLDERS" -eq 1 ]; then
        # Случайная глубина для текущего файла (от 1 до MAX_DEPTH)
        DEPTH=$(shuf -i 1-$MAX_DEPTH -n 1)
        for (( j=1; j<=DEPTH; j++ )); do
            # Генерируем названия папок (например, dir_1, dir_2... до dir_5 для разнообразия)
            DIR_NAME="dir_$(shuf -i 1-5 -n 1)"
            CURRENT_DIR="$CURRENT_DIR/$DIR_NAME"
        done
        mkdir -p "$CURRENT_DIR"
    fi
    
    # 4. Создаем файл
    FILE_PATH="$CURRENT_DIR/file_$(date +%s%N)_$i.log"
    
    # fallocate создает файлы мгновенно. 
    # Если ФС не поддерживает fallocate (редкость), сработает запасной вариант через dd
    fallocate -l "${RAND_SIZE}M" "$FILE_PATH" 2>/dev/null || dd if=/dev/zero of="$FILE_PATH" bs=1M count="$RAND_SIZE" status=none
    
    # 5. Меняем дату модификации и доступа файла
    touch -m -a -d "$RAND_DATE" "$FILE_PATH"
    
    # Выводим прогресс раз в 100 файлов, чтобы не спамить в консоль
    if (( i % 100 == 0 )); then
        echo "Сгенерировано $i из $FILE_COUNT файлов..."
    fi
done

echo "=== Готово! ==="
echo "Папка назначения: $TARGET_DIR"
echo "Объем сгенерированных данных: $(du -sh "$TARGET_DIR" | awk '{print $1}')"
