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
FILE_LIMIT=0
IS_TUI=false
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"
CHECKSUM_FILE=".master_checksum"

trap 'echo -e "\n${RED}Прервано пользователем!${NC}"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [опции]"
    echo "Запуск БЕЗ аргументов откроет графический (TUI) интерфейс."
    echo ""
    echo "Опции:"
    echo "  -f, --flat        Плоская фасовка (ГГГГ-ММ-ДД)"
    echo "  -r, --recursive   Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "  -dc, --date-create Сорт. по дате создания (по умолчанию)"
    echo "  -de, --date-edit   Сорт. по дате изменения"
    echo "  -n, --files N     Лимит файлов"
    echo "  -b, --backup      Сделать 7z бекап"
    echo "  -d, --dry-run     Холостой запуск"
    echo "  --sum             Мастер-хэш ВСЕХ файлов ДО сортировки (отдельно)"
    echo "  --re-sum          Мастер-хэш ВСЕХ файлов ПОСЛЕ сортировки (отдельно)"
    echo "  -t, --target      Целевая директория (дефолт: .)"
    exit 1
}

# --- ПОЛУЧЕНИЕ МЕТРИК ---
get_stats() {
    local load=$(cat /proc/loadavg | awk '{print $1}')
    local ram=$(free -m | awk '/Mem:/ {print $3"MB"}')
    local rom=$(df -h . | awk 'NR==2 {print $5}')
    echo "CPU Load: $load | RAM: $ram | ROM (Disk): $rom"
}

# --- ИНТЕРАКТИВНЫЙ РЕЖИМ (TUI) ---
run_tui() {
    IS_TUI=true
    if ! command -v whiptail &> /dev/null; then
        echo -e "${RED}Утилита whiptail не найдена! Установи пакет libnewt.${NC}"
        exit 1
    fi

    local action_choice
    action_choice=$(whiptail --title "KHTON FILE SORTER" --menu "Выбери действие:" 15 60 4 \
        "1" "Сортировка файлов" \
        "2" "Создать слепок мастер-хэша всей папки (--sum)" \
        "3" "Сверить мастер-хэш всей папки (--re-sum)" \
        "4" "Выход" 3>&1 1>&2 2>&3) || exit 0
    
    case $action_choice in
        1) ACTION="sort" ;;
        2) ACTION="sum" ;;
        3) ACTION="resum" ;;
        4) exit 0 ;;
    esac

    TARGET_DIR=$(whiptail --title "Целевая директория" --inputbox "Введите путь:" 10 60 "." 3>&1 1>&2 2>&3) || exit 0

    if [[ "$ACTION" == "sort" ]]; then
        MODE=$(whiptail --title "Режим фасовки" --menu "Как группировать папки?" 15 60 2 \
            "flat" "Плоская (ГГГГ-ММ-ДД)" \
            "recursive" "Рекурсивная (ГГГГ/ММ/ДД)" 3>&1 1>&2 2>&3) || exit 0

        DATE_MODE=$(whiptail --title "Опции дат" --menu "Какую дату использовать?" 15 60 2 \
            "create" "Дата создания (btime/mtime)" \
            "edit" "Дата изменения (mtime)" 3>&1 1>&2 2>&3) || exit 0

        local limit_input
        limit_input=$(whiptail --title "Лимит" --inputbox "Кол-во файлов для обработки (0 = все):" 10 60 "0" 3>&1 1>&2 2>&3) || exit 0
        if [[ "$limit_input" =~ ^[0-9]+$ ]]; then FILE_LIMIT=$limit_input; fi

        local options_choice
        options_choice=$(whiptail --title "Безопасность" --checklist "Дополнительные опции:" 15 60 2 \
            "BACKUP" "Создать 7z архив перед стартом" OFF \
            "DRY_RUN" "Холостой запуск (Dry-Run)" OFF 3>&1 1>&2 2>&3) || exit 0
        
        [[ $options_choice == *"BACKUP"* ]] && CREATE_BACKUP=true
        [[ $options_choice == *"DRY_RUN"* ]] && DRY_RUN=true
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

if [[ "$FILE_LIMIT" -ne 0 && ! "$FILE_LIMIT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Ошибка: Лимит файлов должен быть числом.${NC}"; exit 1
fi

cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в $TARGET_DIR${NC}"; exit 1; }
script_name=$(basename "$0")

# --- ФУНКЦИИ ГЛОБАЛЬНОГО ХЭШИРОВАНИЯ (--sum / --re-sum) ---
calc_master_hash() {
    find . -type f ! -name "$script_name" ! -name "sort_log_*.txt" ! -name "$CHECKSUM_FILE" ! -name "backup_*.7z" \
        -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}'
}

run_hash_with_ui() {
    local task_name="$1" target_file="$2"
    calc_master_hash > "$target_file" &
    local pid=$!
    local c=0
    set +e
    while kill -0 $pid 2>/dev/null; do
        if $IS_TUI; then
            c=$(( (c + 5) % 100 ))
            local stats=$(get_stats)
            echo "XXX"; echo "$c"; echo -e "${task_name}...\n$stats"; echo "XXX"
        else
            printf "\r${BLUE}${task_name}... [Ожидание]${NC}"
        fi
        sleep 0.5
    done
    set -e
    wait $pid
}

if [[ "$ACTION" == "sum" ]]; then
    if $IS_TUI; then run_hash_with_ui "Вычисление слепка" "$CHECKSUM_FILE" | whiptail --title "Мастер-Хэш" --gauge "Запуск..." 10 70 0; whiptail --title "Успех" --msgbox "Мастер-хэш сохранен!\n\nФайл: $CHECKSUM_FILE" 10 60
    else echo -e "${BLUE}Вычисляю мастер-хэш файлов...${NC}"; run_hash_with_ui "Вычисление слепка" "$CHECKSUM_FILE"; echo -e "\n${GREEN}Готово! Сохранен в $CHECKSUM_FILE${NC}"; fi
    exit 0
fi

if [[ "$ACTION" == "resum" ]]; then
    [[ ! -f "$CHECKSUM_FILE" ]] && { echo -e "${RED}Ошибка: Файл $CHECKSUM_FILE не найден.${NC}"; exit 1; }
    old_hash=$(cat "$CHECKSUM_FILE"); tmp_hash=$(mktemp)
    if $IS_TUI; then run_hash_with_ui "Сверка слепка" "$tmp_hash" | whiptail --title "Проверка Хэша" --gauge "Анализ данных..." 10 70 0
    else echo -e "${BLUE}Сверяю мастер-хэш...${NC}"; run_hash_with_ui "Сверка слепка" "$tmp_hash"; echo ""; fi
    new_hash=$(cat "$tmp_hash"); rm -f "$tmp_hash"
    if [[ "$old_hash" == "$new_hash" ]]; then
        if $IS_TUI; then whiptail --title "УСПЕХ" --msgbox "Чек-суммы совпадают!\nВсе данные на месте и не повреждены." 10 60
        else echo -e "${GREEN}УСПЕХ: Чек-суммы совпадают!${NC}"; fi
        exit 0
    else
        if $IS_TUI; then whiptail --title "ОШИБКА" --msgbox "КРИТИЧЕСКАЯ ОШИБКА!\nЧек-суммы НЕ СОВПАДАЮТ!" 10 60
        else echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Чек-суммы НЕ СОВПАДАЮТ!${NC}"; fi
        exit 1
    fi
fi

# --- ПОДГОТОВКА К СОРТИРОВКЕ ---
[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Не выбран режим (-f или -r)${NC}"; exit 1; }
[[ "$DRY_RUN" == false && ! -w . ]] && { echo -e "${RED}Ошибка: Нет прав на запись${NC}"; exit 1; }

shopt -s dotglob
files=()
for f in *; do
    if [[ -f "$f" && ! -h "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt && "$f" != "$CHECKSUM_FILE" && "$f" != backup_*.7z ]]; then
        files+=("$f")
    fi
done
shopt -u dotglob

total_files=${#files[@]}
[[ $total_files -eq 0 ]] && { echo -e "${BLUE}Нет файлов для сортировки.${NC}"; exit 0; }

if [[ "$FILE_LIMIT" -gt 0 && "$FILE_LIMIT" -lt "$total_files" ]]; then
    files=("${files[@]:0:$FILE_LIMIT}")
    total_files=${#files[@]}
fi

# --- БЕКАП ---
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then echo -e "${RED}Утилита 7z не найдена!${NC}"; exit 1; fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    run_backup_ui() {
        7z a -t7z -mx=9 "$backup_file" . -x!"$script_name" -x!"sort_log_*.txt" -x!"$CHECKSUM_FILE" -x!"backup_*.7z" > /dev/null &
        local pid=$!; local c=0; set +e
        while kill -0 $pid 2>/dev/null; do
            if $IS_TUI; then c=$(( (c + 2) % 100 )); local stats=$(get_stats); echo "XXX"; echo "$c"; echo -e "Сжатие исходников в 7z...\n$stats"; echo "XXX"
            else printf "\r${BLUE}Создаю бекап... [Ожидание]${NC}"; fi; sleep 0.5
        done
        set -e; wait $pid
    }
    if $IS_TUI; then run_backup_ui | whiptail --title "Резервное копирование" --gauge "Подготовка..." 10 70 0
    else run_backup_ui; echo -e "\n${GREEN}Бекап $backup_file создан!${NC}"; fi
fi

# --- ПРОВЕРКА ЦЕЛОСТНОСТИ: ХЭШ ДО ---
DEST_PATHS_FILE=$(mktemp)
PRE_SORT_HASH=""

if [[ "$DRY_RUN" == false ]]; then
    if $IS_TUI; then
        whiptail --title "Безопасность" --infobox "Снимаем слепок ${total_files} файлов ДО сортировки...\nПожалуйста, подождите." 10 60
    else
        echo -e "${BLUE}Снимаю слепок ${total_files} файлов ДО сортировки...${NC}"
    fi
    PRE_SORT_HASH=$(printf "%s\0" "${files[@]}" | xargs -0 sha256sum 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
fi

# --- ФУНКЦИЯ ЦИКЛА СОРТИРОВКИ ---
get_unique_filename() {
    local dir="$1" file="$2" base="${2%.*}" ext="${2##*.}"
    [[ "$base" == "$ext" ]] && ext="" || ext=".$ext"
    local counter=1 new_name="$file"
    while [[ -e "$dir/$new_name" ]]; do
        new_name="${base}_${counter}${ext}"; ((counter++))
    done
    echo "$new_name"
}

run_sort_loop() {
    local current=0 last_stat_time=0 current_stats=""
    for file in "${files[@]}"; do
        ((++current))
        local percent=$((current * 100 / total_files))
        local now=$(date +%s)
        if (( now - last_stat_time >= 1 )); then current_stats=$(get_stats); last_stat_time=$now; fi

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

        if $IS_TUI; then
            echo "XXX"; echo "$percent"; echo -e "Файл: $current / $total_files ($percent%)\n$current_stats"; echo "XXX"
        else
            local filled=$((percent / 2)); local empty=$((50 - filled))
            local bar=$(printf "%${filled}s" | tr ' ' '#'); local space=$(printf "%${empty}s" | tr ' ' '-')
            printf "\r${GREEN}[%s%s] %d%% (%d/%d)${NC}" "$bar" "$space" "$percent" "$current" "$total_files"
        fi
    done
}

echo "--- Сортировка начата: $(date) ---" > "$LOG_FILE"

if $IS_TUI; then
    run_sort_loop | whiptail --title "Сортировка файлов" --gauge "Начинаем фасовку..." 10 70 0
else
    echo -e "${BLUE}Начинаю фасовку ($total_files файлов)...${NC}"
    run_sort_loop
    echo ""
fi

# --- ПРОВЕРКА ЦЕЛОСТНОСТИ: ХЭШ ПОСЛЕ ---
INTEGRITY_STATUS=""
if [[ "$DRY_RUN" == false ]]; then
    if $IS_TUI; then
        whiptail --title "Безопасность" --infobox "Сверяем слепок ПОСЛЕ сортировки...\nПожалуйста, подождите." 10 60
    else
        echo -e "${BLUE}Сверяю хэши файлов ПОСЛЕ сортировки...${NC}"
    fi
    POST_SORT_HASH=$(xargs -0 sha256sum 2>/dev/null < "$DEST_PATHS_FILE" | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
    
    if [[ "$PRE_SORT_HASH" == "$POST_SORT_HASH" ]]; then
        INTEGRITY_STATUS="УСПЕХ: Хэши совпали (100% целостность)."
        echo "[$(date '+%H:%M:%S')] ЦЕЛОСТНОСТЬ OK: $PRE_SORT_HASH" >> "$LOG_FILE"
    else
        INTEGRITY_STATUS="ОШИБКА: Хэши НЕ совпали! (ДО: $PRE_SORT_HASH | ПОСЛЕ: $POST_SORT_HASH)"
        echo "[$(date '+%H:%M:%S')] ОШИБКА ЦЕЛОСТНОСТИ: $PRE_SORT_HASH != $POST_SORT_HASH" >> "$LOG_FILE"
    fi
else
    INTEGRITY_STATUS="Пропущено (Холостой запуск)."
fi
rm -f "$DEST_PATHS_FILE"

echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"

# --- ИТОГИ ---
if $IS_TUI; then
    whiptail --title "Готово" --msgbox "Операция завершена!\n\nЦелостность данных:\n$INTEGRITY_STATUS\n\nЛог сохранен в:\n$LOG_FILE" 15 70
else
    echo -e "${GREEN}Готово!${NC}"
    if [[ "$INTEGRITY_STATUS" == *"ОШИБКА"* ]]; then echo -e "${RED}$INTEGRITY_STATUS${NC}"; else echo -e "${GREEN}$INTEGRITY_STATUS${NC}"; fi
    echo -e "Лог сохранен в: $LOG_FILE"
fi