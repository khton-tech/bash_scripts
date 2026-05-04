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
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"
CHECKSUM_FILE=".master_checksum"

trap 'echo -e "\n${RED}Прервано пользователем!${NC}"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [опции]"
    echo "Запуск БЕЗ аргументов откроет графический (TUI) интерфейс."
    echo ""
    echo "Опции для консольного запуска:"
    echo "  -f,  --flat        Плоская фасовка (ГГГГ-ММ-ДД)"
    echo "  -r,  --recursive   Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "  -dc, --date-create Сортировать по дате создания (по умолчанию)"
    echo "  -de, --date-edit   Сортировать по дате изменения"
    echo "  -n,  --files N     Ограничить кол-во файлов (например, --files 100)"
    echo "  -b,  --backup      Сделать 7z бекап исходников перед сортировкой"
    echo "  -d,  --dry-run     Холостой запуск (без изменений)"
    echo "  --sum              Вычислить мастер-хэш файлов ДО сортировки"
    echo "  --re-sum           Сверить мастер-хэш файлов ПОСЛЕ сортировки"
    echo "  -t,  --target      Целевая директория (дефолт: текущая)"
    exit 1
}

# --- ИНТЕРАКТИВНЫЙ РЕЖИМ (TUI) ---
run_tui() {
    if ! command -v whiptail &> /dev/null; then
        echo -e "${RED}Утилита whiptail не найдена! Установи пакет libnewt.${NC}"
        exit 1
    fi

    # 1. Главное меню
    local action_choice
    action_choice=$(whiptail --title "KHTON FILE SORTER" --menu "Выбери действие:" 15 60 4 \
        "1" "Сортировка файлов" \
        "2" "Создать слепок мастер-хэша (--sum)" \
        "3" "Сверить мастер-хэш (--re-sum)" \
        "4" "Выход" 3>&1 1>&2 2>&3) || exit 0
    
    case $action_choice in
        1) ACTION="sort" ;;
        2) ACTION="sum" ;;
        3) ACTION="resum" ;;
        4) exit 0 ;;
    esac

    # 2. Целевая директория
    TARGET_DIR=$(whiptail --title "Целевая директория" --inputbox "Введите путь (по умолчанию текущая '.'):" 10 60 "." 3>&1 1>&2 2>&3) || exit 0

    # Если выбрана сортировка, спрашиваем детали
    if [[ "$ACTION" == "sort" ]]; then
        # 3. Режим папок
        MODE=$(whiptail --title "Режим фасовки" --menu "Как группировать папки?" 15 60 2 \
            "flat" "Плоская (ГГГГ-ММ-ДД)" \
            "recursive" "Рекурсивная (ГГГГ/ММ/ДД)" 3>&1 1>&2 2>&3) || exit 0

        # 4. Режим дат
        DATE_MODE=$(whiptail --title "Опции дат" --menu "Какую дату использовать?" 15 60 2 \
            "create" "Дата создания (btime/mtime)" \
            "edit" "Дата изменения (mtime)" 3>&1 1>&2 2>&3) || exit 0

        # 5. Лимит файлов
        local limit_input
        limit_input=$(whiptail --title "Лимит" --inputbox "Кол-во файлов для обработки (0 = все):" 10 60 "0" 3>&1 1>&2 2>&3) || exit 0
        if [[ "$limit_input" =~ ^[0-9]+$ ]]; then
            FILE_LIMIT=$limit_input
        fi

        # 6. Чекбокс опций
        local options_choice
        options_choice=$(whiptail --title "Безопасность" --checklist "Дополнительные опции (Пробел - выбор):" 15 60 2 \
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

# Проверка лимита на валидность (только числа)
if [[ "$FILE_LIMIT" -ne 0 && ! "$FILE_LIMIT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Ошибка: Лимит файлов должен быть положительным числом.${NC}"
    exit 1
fi

cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в $TARGET_DIR${NC}"; exit 1; }
script_name=$(basename "$0")

# Функция расчета единого мастер-хэша
calc_master_hash() {
    find . -type f \
        ! -name "$script_name" \
        ! -name "sort_log_*.txt" \
        ! -name "$CHECKSUM_FILE" \
        ! -name "backup_*.7z" \
        -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}'
}

# --- ЛОГИКА ХЭШИРОВАНИЯ ---
if [[ "$ACTION" == "sum" ]]; then
    echo -e "${BLUE}Вычисляю мастер-хэш файлов в '$TARGET_DIR'... Это может занять время.${NC}"
    calc_master_hash > "$CHECKSUM_FILE"
    echo -e "${GREEN}Готово! Мастер-хэш сохранен в '$TARGET_DIR/$CHECKSUM_FILE'${NC}"
    exit 0
fi

if [[ "$ACTION" == "resum" ]]; then
    if [[ ! -f "$CHECKSUM_FILE" ]]; then
        echo -e "${RED}Ошибка: Файл $CHECKSUM_FILE не найден. Сначала выполни --sum.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Сверяю мастер-хэш файлов в '$TARGET_DIR'...${NC}"
    old_hash=$(cat "$CHECKSUM_FILE")
    new_hash=$(calc_master_hash)
    
    echo "Ожидалось: $old_hash"
    echo "Получено:  $new_hash"
    
    if [[ "$old_hash" == "$new_hash" ]]; then
        echo -e "${GREEN}УСПЕХ: Чек-суммы совпадают! Все данные на месте.${NC}"
        exit 0
    else
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Чек-суммы НЕ СОВПАДАЮТ!${NC}"
        exit 1
    fi
fi

# --- ЛОГИКА СОРТИРОВКИ ---
[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Для фасовки выбери режим (-f или -r)${NC}"; exit 1; }
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

if [[ "$FILE_LIMIT" -gt 0 && "$FILE_LIMIT" -lt "$total_files" ]]; then
    echo -e "${YELLOW}Внимание: Установлен лимит. Будет обработано $FILE_LIMIT из $total_files файлов.${NC}"
    files=("${files[@]:0:$FILE_LIMIT}")
    total_files=${#files[@]}
fi

# Бекап
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then
        echo -e "${RED}Ошибка: Утилита '7z' не установлена в системе.${NC}"
        exit 1
    fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    echo -e "${BLUE}Создаю бекап исходников: $backup_file ...${NC}"
    if 7z a -t7z -mx=9 "$backup_file" . -x!"$script_name" -x!"sort_log_*.txt" -x!"$CHECKSUM_FILE" -x!"backup_*.7z" > /dev/null; then
        echo -e "${GREEN}Бекап успешно сохранен!${NC}"
    else
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА создания бекапа. Прерываю работу.${NC}"
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
        [[ ! -d "$dir_name" ]] && mkdir -p "$dir_name"
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