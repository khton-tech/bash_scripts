#!/bin/bash
#
# Утилита для сортировки файлов по дате создания или изменения.
# Поддерживает плоскую (ГГГГ-ММ-ДД) и рекурсивную (ГГГГ/ММ/ДД) структуру директорий.

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

MODE=""
ACTION="sort" # sort, sum, resum
TARGET_DIR="."
DATE_MODE="create"
DRY_RUN=false
CREATE_BACKUP=false
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"
CHECKSUM_FILE=".master_checksum"

trap 'echo -e "\n${RED}Прервано пользователем!${NC}"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [опции]"
    echo "Режимы фасовки:"
    echo "  -f,  --flat        Плоская фасовка (ГГГГ-ММ-ДД)"
    echo "  -r,  --recursive   Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "Опции дат:"
    echo "  -dc, --date-create Сортировать по дате создания (btime). По умолчанию."
    echo "  -de, --date-edit   Сортировать по дате изменения (mtime)."
    echo "Опции безопасности и проверок:"
    echo "  -b,  --backup      Сделать 7z бекап исходников перед сортировкой (макс. сжатие)"
    echo "  -d,  --dry-run     Холостой запуск (без изменений)"
    echo "  --sum              Вычислить мастер-хэш всех файлов ДО сортировки"
    echo "  --re-sum           Сверить мастер-хэш файлов ПОСЛЕ сортировки"
    echo "Другие опции:"
    echo "  -t,  --target      Целевая директория (дефолт: текущая)"
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f|--flat) MODE="flat" ;;
        -r|--recursive) MODE="recursive" ;;
        -t|--target) TARGET_DIR="${2:-}"; shift ;;
        -dc|--date-create) DATE_MODE="create" ;;
        -de|--date-edit) DATE_MODE="edit" ;;
        -b|--backup) CREATE_BACKUP=true ;;
        -d|--dry-run) DRY_RUN=true ;;
        --sum) ACTION="sum" ;;
        --re-sum) ACTION="resum" ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Неизвестный параметр: $1${NC}"; usage ;;
    esac
    shift
done

cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в $TARGET_DIR${NC}"; exit 1; }
script_name=$(basename "$0")

# Функция расчета единого мастер-хэша для всех файлов в директории
calc_master_hash() {
    find . -type f \
        ! -name "$script_name" \
        ! -name "sort_log_*.txt" \
        ! -name "$CHECKSUM_FILE" \
        ! -name "backup_*.7z" \
        -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}'
}

# --- Логика хэширования ---
if [[ "$ACTION" == "sum" ]]; then
    echo -e "${BLUE}Вычисляю мастер-хэш файлов в '$TARGET_DIR'... Это может занять время.${NC}"
    calc_master_hash > "$CHECKSUM_FILE"
    echo -e "${GREEN}Готово! Мастер-хэш сохранен в '$TARGET_DIR/$CHECKSUM_FILE'${NC}"
    exit 0
fi

if [[ "$ACTION" == "resum" ]]; then
    if [[ ! -f "$CHECKSUM_FILE" ]]; then
        echo -e "${RED}Ошибка: Файл $CHECKSUM_FILE не найден. Сначала выполни скрипт с флагом --sum.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Сверяю мастер-хэш файлов в '$TARGET_DIR'...${NC}"
    old_hash=$(cat "$CHECKSUM_FILE")
    new_hash=$(calc_master_hash)
    
    echo "Ожидалось: $old_hash"
    echo "Получено:  $new_hash"
    
    if [[ "$old_hash" == "$new_hash" ]]; then
        echo -e "${GREEN}УСПЕХ: Чек-суммы совпадают! Все данные на месте и не повреждены.${NC}"
        exit 0
    else
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Чек-суммы НЕ СОВПАДАЮТ!${NC}"
        exit 1
    fi
fi

# --- Логика сортировки ---
[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Для фасовки выбери режим (-f или -r)${NC}"; usage; }
[[ "$DRY_RUN" == false && ! -w . ]] && { echo -e "${RED}Ошибка: Нет прав на запись в $TARGET_DIR${NC}"; exit 1; }

shopt -s dotglob
files=()
for f in *; do
    if [[ -f "$f" && ! -h "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt && "$f" != "$CHECKSUM_FILE" && "$f" != backup_*.7z ]]; then
        files+=("$f")
    fi
done
shopt -u dotglob

total_files=${#files[@]}
if [[ $total_files -eq 0 ]]; then
    echo -e "${BLUE}В директории нет файлов для сортировки.${NC}"
    exit 0
fi

# --- Логика бекапа ---
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then
        echo -e "${RED}Ошибка: Утилита '7z' не установлена в системе. Бекап невозможен.${NC}"
        echo -e "${YELLOW}Подсказка: установи p7zip (например, sudo pacman -S p7zip).${NC}"
        exit 1
    fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    echo -e "${BLUE}Создаю бекап исходников (макс. сжатие): $backup_file ...${NC}"
    
    # Архивируем всё в текущей директории (.), исключая мусор и сам скрипт
    if 7z a -t7z -mx=9 "$backup_file" . -x!"$script_name" -x!"sort_log_*.txt" -x!"$CHECKSUM_FILE" -x!"backup_*.7z" > /dev/null; then
        echo -e "${GREEN}Бекап успешно сохранен!${NC}"
    else
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Не удалось создать бекап. Прерываю фасовку во избежание потери данных.${NC}"
        exit 1
    fi
elif [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN] Будет создан 7z архив текущей директории перед сортировкой.${NC}"
fi

echo -e "${BLUE}Начинаю фасовку ($total_files файлов). Режим: $MODE, Дата: $DATE_MODE${NC}"
if $DRY_RUN; then echo -e "${YELLOW}!!! DRY-RUN: ФАЙЛЫ НЕ БУДУТ ПЕРЕМЕЩЕНЫ !!!${NC}"; fi

echo "--- Сортировка начата: $(date) ---" > "$LOG_FILE"
current=0

get_unique_filename() {
    local dir="$1"
    local file="$2"
    local base="${file%.*}"
    local ext="${file##*.}"
    [[ "$base" == "$ext" ]] && ext="" || ext=".$ext"
    
    local counter=1
    local new_name="$file"
    while [[ -e "$dir/$new_name" ]]; do
        new_name="${base}_${counter}${ext}"
        ((counter++))
    done
    echo "$new_name"
}

for file in "${files[@]}"; do
    ((++current))

    if [[ "$DATE_MODE" == "create" ]]; then
        ts=$(stat -c %W "$file" 2>/dev/null || echo 0)
        if [[ "$ts" == "0" || "$ts" == "-" ]]; then
            ts=$(stat -c %Y "$file")
        fi
    else
        ts=$(stat -c %Y "$file")
    fi

    if [[ "$MODE" == "flat" ]]; then
        dir_name=$(date -d "@$ts" "+%Y-%m-%d")
    else
        dir_name=$(date -d "@$ts" "+%Y/%m/%d")
    fi

    dest_filename=$(get_unique_filename "$dir_name" "$file")
    dest_path="$dir_name/$dest_filename"

    if $DRY_RUN; then
        echo "[DRY-RUN] Перемещение: '$file' -> '$dest_path'" >> "$LOG_FILE"
    else
        mkdir -p "$dir_name"
        if mv "$file" "$dest_path"; then
            echo "[$(date '+%H:%M:%S')] Перемещен: '$file' -> '$dest_path'" >> "$LOG_FILE"
        else
            echo "[$(date '+%H:%M:%S')] ОШИБКА: '$file'" >> "$LOG_FILE"
        fi
    fi

    percent=$((current * 100 / total_files))
    filled=$((percent / 2))
    empty=$((50 - filled))
    bar=$(printf "%${filled}s" | tr ' ' '#')
    space=$(printf "%${empty}s" | tr ' ' '-')
    printf "\r${GREEN}[%s%s] %d%% (%d/%d)${NC}" "$bar" "$space" "$percent" "$current" "$total_files"
done

echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"
printf "\n${GREEN}Готово! Лог: %s${NC}\n" "$LOG_FILE"