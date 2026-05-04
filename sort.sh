#!/bin/bash
#
# Утилита для сортировки файлов по дате создания или изменения.
# Версия: Vanilla Bash (Zero Dependencies + Resource Throttling)

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

MODE=""
ACTION="sort"
TARGET_DIR="."
DATE_MODE="create"
DRY_RUN=false
CREATE_BACKUP=false
FILE_LIMIT=0
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"
CHECKSUM_FILE=".master_checksum"

# Ограничитель ресурсов (CPU и Диск)
THROTTLE_CMD="nice -n 19"
if command -v ionice &> /dev/null; then
    # Класс 2 (Best-Effort), Приоритет 7 (самый низкий)
    THROTTLE_CMD="nice -n 19 ionice -c 2 -n 7"
fi

trap 'tput cnorm 2>/dev/null || true; echo -e "\n${RED}Прервано пользователем!${NC}"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [опции]"
    echo "Запуск БЕЗ аргументов откроет интерактивное меню."
    echo ""
    echo "Опции:"
    echo "  -f, --flat        Плоская фасовка (ГГГГ-ММ-ДД)"
    echo "  -r, --recursive   Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "  -dc, --date-create Сорт. по дате создания (по умолчанию)"
    echo "  -de, --date-edit   Сорт. по дате изменения"
    echo "  -n, --files N     Лимит файлов"
    echo "  -b, --backup      Сделать 7z бекап (throttled)"
    echo "  -d, --dry-run     Холостой запуск"
    echo "  --sum             Мастер-хэш ДО сортировки"
    echo "  --re-sum          Мастер-хэш ПОСЛЕ сортировки"
    echo "  -t, --target      Целевая директория (дефолт: .)"
    exit 1
}

get_stats() {
    local load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "N/A")
    local ram=$(free -m 2>/dev/null | awk '/Mem:/ {print $3"MB"}' || echo "N/A")
    local rom=$(df -h . 2>/dev/null | awk 'NR==2 {print $5}' || echo "N/A")
    echo -e "CPU Load: ${YELLOW}$load${NC} | RAM Used: ${YELLOW}$ram${NC} | ROM Used: ${YELLOW}$rom${NC}"
}

run_interactive() {
    clear
    echo -e "${BLUE}=== KHTON FILE SORTER ===${NC}\n"
    
    echo "Выберите действие:"
    echo "1) Сортировка файлов"
    echo "2) Создать слепок всей папки (--sum)"
    echo "3) Сверить слепок всей папки (--re-sum)"
    echo "4) Выход"
    read -rp "Ввод (1-4): " act_choice
    
    case "$act_choice" in
        1) ACTION="sort" ;;
        2) ACTION="sum" ;;
        3) ACTION="resum" ;;
        *) exit 0 ;;
    esac

    read -rp "Целевая директория [нажми Enter для текущей '.']: " dir_input
    [[ -n "$dir_input" ]] && TARGET_DIR="$dir_input"

    if [[ "$ACTION" == "sort" ]]; then
        echo -e "\nРежим фасовки:"
        echo "1) Плоская (ГГГГ-ММ-ДД)"
        echo "2) Рекурсивная (ГГГГ/ММ/ДД)"
        read -rp "Ввод (1-2): " mode_choice
        [[ "$mode_choice" == "1" ]] && MODE="flat" || MODE="recursive"

        echo -e "\nОпция даты:"
        echo "1) Дата создания (btime/mtime)"
        echo "2) Дата изменения (mtime)"
        read -rp "Ввод (1-2): " date_choice
        [[ "$date_choice" == "2" ]] && DATE_MODE="edit" || DATE_MODE="create"

        read -rp $'\nЛимит файлов для обработки [Enter = все]: ' limit_input
        if [[ "$limit_input" =~ ^[0-9]+$ ]]; then FILE_LIMIT=$limit_input; fi

        echo -e "\nДополнительные опции:"
        read -rp "Создать безопасный 7z бекап перед стартом? (y/N): " backup_choice
        [[ "${backup_choice,,}" == "y" ]] && CREATE_BACKUP=true

        read -rp "Включить холостой запуск (Dry-Run)? (y/N): " dry_choice
        [[ "${dry_choice,,}" == "y" ]] && DRY_RUN=true
    fi
    echo "----------------------------------------"
}

if [[ "$#" -eq 0 ]]; then
    run_interactive
else
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -f|--flat) MODE="flat" ;;
            -r|--recursive) MODE="recursive" ;;
            -t|--target) TARGET_DIR="${2:-}"; shift ;;
            -dc|--date-create) DATE_MODE="create" ;;
            -de|--date-edit) DATE_MODE="edit" ;;
            -n|--files) FILE_LIMIT="${2:-}"; shift ;;
            -b|--backup) CREATE_BACKUP=true ;;
            -d|--dry-run) DRY_RUN=true ;;
            --sum) ACTION="sum" ;;
            --re-sum) ACTION="resum" ;;
            -h|--help) usage ;;
            *) echo -e "${RED}Неизвестный параметр: $1${NC}"; usage ;;
        esac
        shift
    done
fi

[[ "$FILE_LIMIT" -ne 0 && ! "$FILE_LIMIT" =~ ^[0-9]+$ ]] && { echo -e "${RED}Ошибка: Лимит должен быть числом.${NC}"; exit 1; }
cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в $TARGET_DIR${NC}"; exit 1; }
script_name=$(basename "$0")

# Обновленная команда поиска, защищенная THROTTLE_CMD
export CMD_HASH_ALL="find . -type f ! -name '$script_name' ! -name 'sort_log_*.txt' ! -name '$CHECKSUM_FILE' ! -name 'backup_*.7z' -print0 | xargs -0 sha256sum 2>/dev/null | awk '{print \$1}' | sort | sha256sum | awk '{print \$1}'"

if [[ "$ACTION" == "sum" ]]; then
    echo -e "${BLUE}Вычисляю мастер-хэш (низкий приоритет CPU/IO)...${NC}"
    # Обернули выполнение в лимиты
    eval "$THROTTLE_CMD bash -c \"$CMD_HASH_ALL > '$CHECKSUM_FILE'\""
    echo -e "${GREEN}УСПЕХ! Мастер-хэш сохранен в $CHECKSUM_FILE${NC}"
    exit 0
fi

if [[ "$ACTION" == "resum" ]]; then
    [[ ! -f "$CHECKSUM_FILE" ]] && { echo -e "${RED}Ошибка: $CHECKSUM_FILE не найден.${NC}"; exit 1; }
    old_hash=$(cat "$CHECKSUM_FILE")
    tmp_hash=$(mktemp)
    
    echo -e "${BLUE}Сверяю данные с мастер-хэшем (низкий приоритет CPU/IO)...${NC}"
    eval "$THROTTLE_CMD bash -c \"$CMD_HASH_ALL > '$tmp_hash'\""
    new_hash=$(cat "$tmp_hash"); rm -f "$tmp_hash"
    
    if [[ "$old_hash" == "$new_hash" ]]; then
        echo -e "${GREEN}✅ ЦЕЛОСТНОСТЬ ПОДТВЕРЖДЕНА: Чек-суммы совпадают!${NC}"
    else
        echo -e "${RED}❌ КРИТИЧЕСКАЯ ОШИБКА: Чек-суммы НЕ СОВПАДАЮТ!${NC}"
        exit 1
    fi
    exit 0
fi

[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Не выбран режим фасовки (-f или -r)${NC}"; exit 1; }

shopt -s dotglob
files=()
for f in *; do
    if [[ -f "$f" && ! -h "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt && "$f" != "$CHECKSUM_FILE" && "$f" != backup_*.7z ]]; then
        files+=("$f")
    fi
done
shopt -u dotglob

total_files=${#files[@]}
[[ $total_files -eq 0 ]] && { echo -e "${YELLOW}Нет файлов для сортировки.${NC}"; exit 0; }

if [[ "$FILE_LIMIT" -gt 0 && "$FILE_LIMIT" -lt "$total_files" ]]; then
    files=("${files[@]:0:$FILE_LIMIT}")
    total_files=${#files[@]}
    echo -e "${YELLOW}Применен лимит: сортируем первые $FILE_LIMIT файлов.${NC}"
fi

# --- БЕКАП 7Z (THROTTLED) ---
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then 
        echo -e "${RED}Утилита 7z не найдена!${NC}"
        exit 1
    fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    echo -e "${BLUE}Создаю бекап исходников ($backup_file)...${NC}"
    # -mx=5 (нормальное сжатие, мало ОЗУ), -mmt=2 (ограничение до 2 потоков)
    eval "$THROTTLE_CMD 7z a -t7z -mx=5 -mmt=2 '$backup_file' . -x!'$script_name' -x!'sort_log_*.txt' -x!'$CHECKSUM_FILE' -x!'backup_*.7z' > /dev/null"
    echo -e "${GREEN}Бекап успешно сохранен!${NC}"
fi

TMP_FILES_LIST=$(mktemp)
printf "%s\0" "${files[@]}" > "$TMP_FILES_LIST"
PRE_SORT_HASH_FILE=$(mktemp)
DEST_PATHS_FILE=$(mktemp)
PRE_SORT_HASH=""

if [[ "$DRY_RUN" == false ]]; then
    echo -e "${BLUE}Снимаю атомарный слепок ДО сортировки...${NC}"
    eval "$THROTTLE_CMD bash -c \"xargs -0 sha256sum < '$TMP_FILES_LIST' 2>/dev/null | awk '{print \\\$1}' | sort | sha256sum | awk '{print \\\$1}' > '$PRE_SORT_HASH_FILE'\""
    PRE_SORT_HASH=$(cat "$PRE_SORT_HASH_FILE")
fi

get_unique_filename() {
    local dir="$1" file="$2" base="${2%.*}" ext="${2##*.}"
    [[ "$base" == "$ext" ]] && ext="" || ext=".$ext"
    local counter=1 new_name="$file"
    while [[ -e "$dir/$new_name" ]]; do
        new_name="${base}_${counter}${ext}"; ((counter++))
    done
    echo "$new_name"
}

echo "--- Сортировка начата: $(date) ---" > "$LOG_FILE"
echo -e "${BLUE}🚀 Начинаем фасовку...${NC}"
echo "" 
echo "" 

tput civis

current=0
last_stat_time=0
current_stats="$(get_stats)"

for file in "${files[@]}"; do
    ((++current))
    percent=$((current * 100 / total_files))
    
    now=$(date +%s)
    if (( now - last_stat_time >= 1 )); then
        current_stats=$(get_stats)
        last_stat_time=$now
    fi

    if [[ "$DATE_MODE" == "create" ]]; then
        ts=$(stat -c %W "$file" 2>/dev/null || echo 0)
        [[ "$ts" == "0" || "$ts" == "-" ]] && ts=$(stat -c %Y "$file")
    else
        ts=$(stat -c %Y "$file")
    fi

    if [[ "$MODE" == "flat" ]]; then dir_name=$(date -d "@$ts" "+%Y-%m-%d")
    else dir_name=$(date -d "@$ts" "+%Y/%m/%d"); fi

    dest_filename=$(get_unique_filename "$dir_name" "$file")
    dest_path="$dir_name/$dest_filename"

    if $DRY_RUN; then
        echo "[DRY-RUN] $file -> $dest_path" >> "$LOG_FILE"
    else
        [[ ! -d "$dir_name" ]] && mkdir -p "$dir_name"
        if mv "$file" "$dest_path"; then
            echo "[$(date '+%H:%M:%S')] OK: $file -> $dest_path" >> "$LOG_FILE"
            printf "%s\0" "$dest_path" >> "$DEST_PATHS_FILE"
        fi
    fi

    filled=$((percent / 2)); empty=$((50 - filled))
    bar=$(printf "%${filled}s" | tr ' ' '█'); space=$(printf "%${empty}s" | tr ' ' '░')
    
    printf "\033[2A\033[K%s\n\033[K${GREEN}[%s%s] %d%% (%d/%d)${NC}\n" "$current_stats" "$bar" "$space" "$percent" "$current" "$total_files"

    # Даем системе подышать. 0.01 секунды достаточно, чтобы не вешать очередь I/O.
    sleep 0.01
done

tput cnorm

INTEGRITY_STATUS=""
if [[ "$DRY_RUN" == false ]]; then
    echo -e "${BLUE}Сверяю атомарный слепок ПОСЛЕ сортировки...${NC}"
    POST_SORT_HASH_FILE=$(mktemp)
    eval "$THROTTLE_CMD bash -c \"xargs -0 sha256sum < '$DEST_PATHS_FILE' 2>/dev/null | awk '{print \\\$1}' | sort | sha256sum | awk '{print \\\$1}' > '$POST_SORT_HASH_FILE'\""
    POST_SORT_HASH=$(cat "$POST_SORT_HASH_FILE")
    
    if [[ "$PRE_SORT_HASH" == "$POST_SORT_HASH" ]]; then
        INTEGRITY_STATUS="${GREEN}✅ ЦЕЛОСТНОСТЬ: 100% (Хэши совпали)${NC}"
        echo "[$(date '+%H:%M:%S')] ЦЕЛОСТНОСТЬ OK: $PRE_SORT_HASH" >> "$LOG_FILE"
    else
        INTEGRITY_STATUS="${RED}❌ ОШИБКА ЦЕЛОСТНОСТИ! Данные могли повредиться.${NC}"
        echo "[$(date '+%H:%M:%S')] ОШИБКА ЦЕЛОСТНОСТИ: $PRE_SORT_HASH != $POST_SORT_HASH" >> "$LOG_FILE"
    fi
    rm -f "$POST_SORT_HASH_FILE"
else
    INTEGRITY_STATUS="${YELLOW}ℹ️ Пропущено (Dry-Run)${NC}"
fi

rm -f "$TMP_FILES_LIST" "$PRE_SORT_HASH_FILE" "$DEST_PATHS_FILE"
echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"

echo "----------------------------------------"
echo -e "Готово! Обработано файлов: $total_files"
echo -e "$INTEGRITY_STATUS"
echo -e "Подробности в логе: $LOG_FILE"