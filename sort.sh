#!/bin/bash
# Включаем строгий режим для отлова ошибок
set -euo pipefail

# Цветовая палитра
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Дефолтные настройки
MODE=""
TARGET_DIR="."
DATE_MODE="create" # По умолчанию сортируем по дате создания
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"

# Элегантное прерывание по Ctrl+C
trap 'echo -e "\n${RED}Прервано пользователем!${NC}"; echo "--- Сортировка прервана: $(date) ---" >> "$LOG_FILE"; exit 2' INT TERM

usage() {
    echo -e "Использование: $0 [-f | -r] [опции]"
    echo "Режимы фасовки (обязательно выбрать один):"
    echo "  -f,  --flat       Плоская фасовка (ДД-ММ-ГГГГ)"
    echo "  -r,  --recursive  Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "Опции дат:"
    echo "  -dc, --date-create Сортировать по дате создания (btime). По умолчанию."
    echo "  -de, --date-edit   Сортировать по дате изменения (mtime)."
    echo "Другие опции:"
    echo "  -t,  --target     Целевая директория (дефолт: текущая)"
    exit 1
}

# Парсинг аргументов (как в mock-generator)
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f|--flat) MODE="flat" ;;
        -r|--recursive) MODE="recursive" ;;
        -t|--target) TARGET_DIR="${2:-}"; shift ;;
        -dc|--date-create) DATE_MODE="create" ;;
        -de|--date-edit) DATE_MODE="edit" ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Неизвестный параметр: $1${NC}"; usage ;;
    esac
    shift
done

[[ -z "$MODE" ]] && { echo -e "${RED}Ошибка: Необходимо выбрать режим фасовки (-f или -r)${NC}"; usage; }
[[ -z "$TARGET_DIR" ]] && { echo -e "${RED}Ошибка: Не указана целевая директория${NC}"; usage; }

# Переход в папку и проверка прав
cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в директорию $TARGET_DIR${NC}"; exit 1; }
[[ -w . ]] || { echo -e "${RED}Ошибка: Нет прав на запись в $TARGET_DIR${NC}"; exit 1; }

# Включаем обработку скрытых файлов (.env, .gitignore и т.д.)
shopt -s dotglob
script_name=$(basename "$0")
files=()

# Собираем файлы
for f in *; do
    if [[ -f "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt ]]; then
        files+=("$f")
    fi
done
shopt -u dotglob # Выключаем обратно на всякий случай

total_files=${#files[@]}
if [[ $total_files -eq 0 ]]; then
    echo -e "${BLUE}В директории нет файлов для сортировки.${NC}"
    exit 0
fi

echo -e "${BLUE}Начинаю фасовку ($total_files файлов). Режим: $MODE, Дата: $DATE_MODE${NC}"
echo "--- Сортировка начата: $(date) ---" > "$LOG_FILE"
echo "Параметры: Режим=$MODE, Опция_Даты=$DATE_MODE" >> "$LOG_FILE"

current=0

for file in "${files[@]}"; do
    ((current++))

    # Извлекаем UNIX timestamp в зависимости от флага
    if [[ "$DATE_MODE" == "create" ]]; then
        # Пробуем получить Birth time. Если ФС не поддерживает, stat %W вернет 0
        ts=$(stat -c %W "$file" 2>/dev/null || echo 0)
        if [[ "$ts" == "0" || "$ts" == "-" ]]; then
            ts=$(stat -c %Y "$file") # Фолбэк на mtime, если btime недоступен
        fi
    else
        ts=$(stat -c %Y "$file") # Только mtime (date-edit)
    fi

    # Формируем имя директории на основе timestamp
    if [[ "$MODE" == "flat" ]]; then
        dir_name=$(date -d "@$ts" "+%d-%m-%Y")
    else
        dir_name=$(date -d "@$ts" "+%Y/%m/%d")
    fi

    # Создаем папку и безопасно перемещаем (-n не даст затереть файл при коллизии имен)
    mkdir -p "$dir_name"
    if mv -n "$file" "$dir_name/"; then
        echo "[$(date '+%H:%M:%S')] Перемещен: '$file' -> '$dir_name/'" >> "$LOG_FILE"
    else
        echo "[$(date '+%H:%M:%S')] ОШИБКА КОЛЛИЗИИ: '$file' уже существует в '$dir_name/'" >> "$LOG_FILE"
    fi

    # Отрисовка прогресс-бара
    percent=$((current * 100 / total_files))
    filled=$((percent / 2))
    empty=$((50 - filled))
    bar=$(printf "%${filled}s" | tr ' ' '#')
    space=$(printf "%${empty}s" | tr ' ' '-')
    
    printf "\r${GREEN}[%s%s] %d%% (%d/%d)${NC}" "$bar" "$space" "$percent" "$current" "$total_files"
done

echo -e "\n--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"
printf "\n${GREEN}Готово! Лог сохранен в: %s${NC}\n" "$LOG_FILE"