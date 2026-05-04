#!/bin/bash
#
# Утилита для сортировки файлов по дате создания или изменения.
# Интерфейс TUI построен на базе 'gum' (Charmbracelet).

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
FILE_LIMIT=0
IS_TUI=false
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"
CHECKSUM_FILE=".master_checksum"

trap 'echo -e "\n${RED}Прервано пользователем!${NC}"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [опции]"
    echo "Запуск БЕЗ аргументов откроет графический интерфейс (Gum)."
    echo ""
    echo "Опции:"
    echo "  -f, --flat        Плоская фасовка (ГГГГ-ММ-ДД)"
    echo "  -r, --recursive   Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "  -dc, --date-create Сорт. по дате создания (по умолчанию)"
    echo "  -de, --date-edit   Сорт. по дате изменения"
    echo "  -n, --files N     Лимит файлов"
    echo "  -b, --backup      Сделать 7z бекап"
    echo "  -d, --dry-run     Холостой запуск"
    echo "  --sum             Мастер-хэш ВСЕХ файлов ДО сортировки"
    echo "  --re-sum          Мастер-хэш ВСЕХ файлов ПОСЛЕ сортировки"
    echo "  -t, --target      Целевая директория (дефолт: .)"
    exit 1
}

# --- ПОЛУЧЕНИЕ МЕТРИК ---
get_stats() {
    local load=$(cat /proc/loadavg | awk '{print $1}')
    local ram=$(free -m | awk '/Mem:/ {print $3"MB"}')
    local rom=$(df -h . | awk 'NR==2 {print $5}')
    echo -e "CPU: ${YELLOW}$load${NC} | RAM: ${YELLOW}$ram${NC} | ROM: ${YELLOW}$rom${NC}"
}

# --- ИНТЕРАКТИВНЫЙ РЕЖИМ (GUM TUI) ---
run_tui() {
    IS_TUI=true
    if ! command -v gum &> /dev/null; then
        echo -e "${RED}Утилита gum не найдена! Установи: sudo pacman -S gum${NC}"
        exit 1
    fi

    clear
    gum style --border double --margin "1" --padding "1 2" --border-foreground 212 --foreground 212 "KHTON FILE SORTER"
    
    local action_choice
    action_choice=$(gum choose "Сортировка файлов" "Создать слепок всей папки (--sum)" "Сверить слепок всей папки (--re-sum)" "Выход")
    
    case "$action_choice" in
        "Сортировка файлов") ACTION="sort" ;;
        "Создать слепок всей папки (--sum)") ACTION="sum" ;;
        "Сверить слепок всей папки (--re-sum)") ACTION="resum" ;;
        "Выход"|*) exit 0 ;;
    esac

    TARGET_DIR=$(gum input --prompt "Целевая директория ❯ " --placeholder "Путь (по умолчанию .)" --value ".")
    [[ -z "$TARGET_DIR" ]] && TARGET_DIR="."

    if [[ "$ACTION" == "sort" ]]; then
        gum style --foreground 99 "Режим фасовки:"
        local mode_c=$(gum choose "Плоская (ГГГГ-ММ-ДД)" "Рекурсивная (ГГГГ/ММ/ДД)")
        [[ "$mode_c" == *"Плоская"* ]] && MODE="flat" || MODE="recursive"

        gum style --foreground 99 "Опция даты:"
        local date_c=$(gum choose "Дата создания (btime/mtime)" "Дата изменения (mtime)")
        [[ "$date_c" == *"создания"* ]] && DATE_MODE="create" || DATE_MODE="edit"

        local limit_input=$(gum input --prompt "Лимит файлов (0 = все) ❯ " --value "0")
        if [[ "$limit_input" =~ ^[0-9]+$ ]]; then FILE_LIMIT=$limit_input; fi

        gum style --foreground 99 "Безопасность (пробел - выбрать, enter - подтвердить):"
        local options_choice=$(gum choose --no-limit "Создать 7z архив перед стартом" "Холостой запуск (Dry-Run)")
        
        [[ "$options_choice" == *"7z"* ]] && CREATE_BACKUP=true
        [[ "$options_choice" == *"Dry-Run"* ]] && DRY_RUN=true
    fi
    clear
}

# --- ПАРСИНГ АРГУМЕНТОВ ---
if [[ "$#" -eq 0 ]]; then
    run_tui
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

export CMD_HASH_ALL="find . -type f ! -name '$script_name' ! -name 'sort_log_*.txt' ! -name '$CHECKSUM_FILE' ! -name 'backup_*.7z' -exec sha256sum {} + 2>/dev/null | awk '{print \$1}' | sort | sha256sum | awk '{print \$1}'"

# --- ЛОГИКА ГЛОБАЛЬНОГО ХЭШИРОВАНИЯ ---
if [[ "$ACTION" == "sum" ]]; then
    if $IS_TUI; then
        gum spin --spinner dot --title "Считаем мастер-хэш директории..." -- bash -c "$CMD_HASH_ALL > '$CHECKSUM_FILE'"
        gum style --foreground 212 --border normal --padding "1 2" "УСПЕХ! Мастер-хэш сохранен в $CHECKSUM_FILE"
    else
        echo -e "${BLUE}Вычисляю мастер-хэш...${NC}"
        bash -c "$CMD_HASH_ALL > '$CHECKSUM_FILE'"
        echo -e "${GREEN}Сохранен в $CHECKSUM_FILE${NC}"
    fi
    exit 0
fi

if [[ "$ACTION" == "resum" ]]; then
    [[ ! -f "$CHECKSUM_FILE" ]] && { echo -e "${RED}Ошибка: $CHECKSUM_FILE не найден.${NC}"; exit 1; }
    old_hash=$(cat "$CHECKSUM_FILE")
    tmp_hash=$(mktemp)
    
    if $IS_TUI; then
        gum spin --spinner dot --title "Сверяем данные с мастер-хэшем..." -- bash -c "$CMD_HASH_ALL > '$tmp_hash'"
    else
        echo -e "${BLUE}Сверяю хэши...${NC}"
        bash -c "$CMD_HASH_ALL > '$tmp_hash'"
    fi
    
    new_hash=$(cat "$tmp_hash"); rm -f "$tmp_hash"
    
    if [[ "$old_hash" == "$new_hash" ]]; then
        if $IS_TUI; then gum style --foreground 46 --border double --padding "1 2" "ЦЕЛОСТНОСТЬ ПОДТВЕРЖДЕНА!"; 
        else echo -e "${GREEN}УСПЕХ: Чек-суммы совпадают!${NC}"; fi
    else
        if $IS_TUI; then gum style --foreground 196 --border double --padding "1 2" "КРИТИЧЕСКАЯ ОШИБКА: Хэши не совпадают!";
        else echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Чек-суммы НЕ СОВПАДАЮТ!${NC}"; fi
        exit 1
    fi
    exit 0
fi

# --- СБОР ФАЙЛОВ ДЛЯ СОРТИРОВКИ ---
[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Не выбран режим фасовки${NC}"; exit 1; }

shopt -s dotglob
files=()
for f in *; do
    if [[ -f "$f" && ! -h "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt && "$f" != "$CHECKSUM_FILE" && "$f" != backup_*.7z ]]; then
        files+=("$f")
    fi
done
shopt -u dotglob

total_files=${#files[@]}
[[ $total_files -eq 0 ]] && { gum style --foreground 214 "Нет файлов для сортировки."; exit 0; }

if [[ "$FILE_LIMIT" -gt 0 && "$FILE_LIMIT" -lt "$total_files" ]]; then
    files=("${files[@]:0:$FILE_LIMIT}")
    total_files=${#files[@]}
fi

# --- БЕКАП 7Z ---
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then echo -e "${RED}Утилита 7z не найдена!${NC}"; exit 1; fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    export CMD_BACKUP="7z a -t7z -mx=9 '$backup_file' . -x!'$script_name' -x!'sort_log_*.txt' -x!'$CHECKSUM_FILE' -x!'backup_*.7z' > /dev/null"
    
    if $IS_TUI; then
        gum spin --spinner line --title "Создаем 7z бекап исходников ($backup_file)..." -- bash -c "$CMD_BACKUP"
    else
        echo -e "${BLUE}Создаю бекап...${NC}"
        bash -c "$CMD_BACKUP"
    fi
fi

# --- АТОМАРНАЯ ПРОВЕРКА (ХЭШ ДО) ---
TMP_FILES_LIST=$(mktemp)
printf "%s\0" "${files[@]}" > "$TMP_FILES_LIST"
PRE_SORT_HASH_FILE=$(mktemp)
DEST_PATHS_FILE=$(mktemp)
PRE_SORT_HASH=""

if [[ "$DRY_RUN" == false ]]; then
    export CMD_PRE_HASH="xargs -0 sha256sum < '$TMP_FILES_LIST' 2>/dev/null | awk '{print \$1}' | sort | sha256sum | awk '{print \$1}' > '$PRE_SORT_HASH_FILE'"
    if $IS_TUI; then
        gum spin --spinner points --title "Снимаем атомарный слепок $total_files файлов ДО сортировки..." -- bash -c "$CMD_PRE_HASH"
    else
        echo -e "${BLUE}Снимаю слепок ДО сортировки...${NC}"
        bash -c "$CMD_PRE_HASH"
    fi
    PRE_SORT_HASH=$(cat "$PRE_SORT_HASH_FILE")
fi

# --- СОРТИРОВКА (С МЕТРИКАМИ В РЕАЛЬНОМ ВРЕМЕНИ) ---
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
gum style --foreground 212 "🚀 Начинаем фасовку..."
echo "" # Пустая строка для прогресс-бара

current=0
last_stat_time=0
current_stats=""

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

    # Отрисовка метрик и прогресс-бара (затираем предыдущие 2 строки)
    filled=$((percent / 2)); empty=$((50 - filled))
    bar=$(printf "%${filled}s" | tr ' ' '█'); space=$(printf "%${empty}s" | tr ' ' '░')
    
    printf "\033[2A\033[K%s\n\033[K${GREEN}[%s%s] %d%% (%d/%d)${NC}\n" "$current_stats" "$bar" "$space" "$percent" "$current" "$total_files"
done

# --- АТОМАРНАЯ ПРОВЕРКА (ХЭШ ПОСЛЕ) ---
INTEGRITY_STATUS=""
if [[ "$DRY_RUN" == false ]]; then
    POST_SORT_HASH_FILE=$(mktemp)
    export CMD_POST_HASH="xargs -0 sha256sum < '$DEST_PATHS_FILE' 2>/dev/null | awk '{print \$1}' | sort | sha256sum | awk '{print \$1}' > '$POST_SORT_HASH_FILE'"
    
    if $IS_TUI; then
        gum spin --spinner points --title "Сверяем атомарный слепок ПОСЛЕ сортировки..." -- bash -c "$CMD_POST_HASH"
    else
        bash -c "$CMD_POST_HASH"
    fi
    POST_SORT_HASH=$(cat "$POST_SORT_HASH_FILE")
    
    if [[ "$PRE_SORT_HASH" == "$POST_SORT_HASH" ]]; then
        INTEGRITY_STATUS="✅ ЦЕЛОСТНОСТЬ: 100% (Хэши совпали)"
        echo "[$(date '+%H:%M:%S')] ЦЕЛОСТНОСТЬ OK: $PRE_SORT_HASH" >> "$LOG_FILE"
    else
        INTEGRITY_STATUS="❌ ОШИБКА ЦЕЛОСТНОСТИ! Данные могли повредиться."
        echo "[$(date '+%H:%M:%S')] ОШИБКА ЦЕЛОСТНОСТИ: $PRE_SORT_HASH != $POST_SORT_HASH" >> "$LOG_FILE"
    fi
    rm -f "$POST_SORT_HASH_FILE"
else
    INTEGRITY_STATUS="ℹ️ Пропущено (Dry-Run)"
fi

rm -f "$TMP_FILES_LIST" "$PRE_SORT_HASH_FILE" "$DEST_PATHS_FILE"
echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"

# --- ИТОГИ ---
gum style --border rounded --margin "1" --padding "1 2" --border-foreground 46 \
  "Готово! Обработано файлов: $total_files" \
  "$INTEGRITY_STATUS" \
  "Подробности в: $LOG_FILE"