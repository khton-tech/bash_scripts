#!/bin/bash
#
# Утилита для сортировки файлов по дате создания или изменения.
# Версия: Vanilla Bash + Ultra-Fast File Gathering + Benchmark

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

MODE=""
TARGET_DIR="."
DATE_MODE="create"
DRY_RUN=false
CREATE_BACKUP=false
FILE_LIMIT=0
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"

# Ограничитель ресурсов (CPU и Диск)
THROTTLE_CMD="nice -n 19"
if command -v ionice &> /dev/null; then
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
    echo "  -b, --backup      Сделать 7z бекап"
    echo "  -d, --dry-run     Холостой запуск"
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
    
    read -rp "Целевая директория [нажми Enter для текущей '.']: " dir_input
    [[ -n "$dir_input" ]] && TARGET_DIR="$dir_input"

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
            -h|--help) usage ;;
            *) echo -e "${RED}Неизвестный параметр: $1${NC}"; usage ;;
        esac
        shift
    done
fi

[[ "$FILE_LIMIT" -ne 0 && ! "$FILE_LIMIT" =~ ^[0-9]+$ ]] && { echo -e "${RED}Ошибка: Лимит должен быть числом.${NC}"; exit 1; }
cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в $TARGET_DIR${NC}"; exit 1; }
script_name=$(basename "$0")

[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Не выбран режим фасовки (-f или -r)${NC}"; exit 1; }

# --- ОПТИМИЗИРОВАННЫЙ СБОР ФАЙЛОВ ---
echo -e "${BLUE}Собираю список файлов...${NC}"
files=()

while IFS= read -r -d $'\0' f; do
    f="${f#./}" 
    
    [[ "$f" == "$script_name" ]] && continue
    [[ "$f" == sort_log_*.txt ]] && continue
    [[ "$f" == backup_*.7z ]] && continue

    files+=("$f")
    
    if [[ "$FILE_LIMIT" -gt 0 && "${#files[@]}" -ge "$FILE_LIMIT" ]]; then
        break
    fi
done < <(find . -maxdepth 1 -type f -print0)

total_files=${#files[@]}
[[ $total_files -eq 0 ]] && { echo -e "${YELLOW}Нет файлов для сортировки.${NC}"; exit 0; }

if [[ "$FILE_LIMIT" -gt 0 ]]; then
    echo -e "${YELLOW}Собран лимит: $total_files файлов.${NC}"
fi

# --- БЕКАП 7Z (THROTTLED) ---
if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false ]]; then
    if ! command -v 7z &> /dev/null; then 
        echo -e "${RED}Утилита 7z не найдена!${NC}"
        exit 1
    fi
    backup_file="backup_$(date +%Y%m%d_%H%M%S).7z"
    echo -e "${BLUE}Создаю бекап исходников ($backup_file)...${NC}"
    eval "$THROTTLE_CMD 7z a -t7z -mx=5 -mmt=2 '$backup_file' . -x!'$script_name' -x!'sort_log_*.txt' -x!'backup_*.7z' > /dev/null"
    echo -e "${GREEN}Бекап успешно сохранен!${NC}"
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

# ЗАПУСК БЕНЧМАРКА
bench_start=$(date +%s.%N)

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
        fi
    fi

    filled=$((percent / 2)); empty=$((50 - filled))
    bar=$(printf "%${filled}s" | tr ' ' '█'); space=$(printf "%${empty}s" | tr ' ' '░')
    
    printf "\033[2A\033[K%s\n\033[K${GREEN}[%s%s] %d%% (%d/%d)${NC}\n" "$current_stats" "$bar" "$space" "$percent" "$current" "$total_files"
done

# ОСТАНОВКА БЕНЧМАРКА И ПОДСЧЕТ
bench_end=$(date +%s.%N)
total_time=$(awk "BEGIN {printf \"%.2f\", $bench_end - $bench_start}")
avg_time=$(awk "BEGIN {printf \"%.5f\", $total_time / $total_files}")

tput cnorm

echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"
echo "Общее время: ${total_time} сек" >> "$LOG_FILE"
echo "Среднее время на файл: ${avg_time} сек" >> "$LOG_FILE"

echo "----------------------------------------"
echo -e "${GREEN}Готово! Обработано файлов: $total_files${NC}"
echo -e "${YELLOW}⏱️  Общее время работы: ${total_time} секунд${NC}"
echo -e "${YELLOW}⚡ Среднее время на 1 файл: ${avg_time} секунд${NC}"
echo "----------------------------------------"
echo -e "Подробности в логе: $LOG_FILE"