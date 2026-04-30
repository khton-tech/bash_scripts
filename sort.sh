#!/bin/bash

# Цветовая палитра для вывода
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # Сброс цвета

MODE=""
TARGET_DIR="."
LOG_FILE="sort_log_$(date +%Y%m%d_%H%M%S).txt"

# Функция справки и вывода ошибок
usage() {
    echo -e "${RED}Ошибка: Неверное использование флагов.${NC}"
    echo "Использование: $0 [-f | -r] [-d путь]"
    echo "  -f    Плоская фасовка (ДД-ММ-ГГГГ)"
    echo "  -r    Рекурсивная фасовка (ГГГГ/ММ/ДД)"
    echo "  -d    Указать целевую директорию (по умолчанию текущая)"
    exit 1
}

# Парсинг аргументов
while getopts "frd:" opt; do
    case $opt in
        f) 
            [[ -n "$MODE" ]] && usage
            MODE="flat" 
            ;;
        r) 
            [[ -n "$MODE" ]] && usage
            MODE="recursive" 
            ;;
        d) TARGET_DIR="$OPTARG" ;;
        *) usage ;;
    esac
done

# Проверка, выбран ли режим
if [[ -z "$MODE" ]]; then
    usage
fi

cd "$TARGET_DIR" || { echo -e "${RED}Ошибка: Не удалось перейти в директорию $TARGET_DIR${NC}"; exit 1; }

# Собираем файлы (игнорируем сам скрипт, лог и директории)
script_name=$(basename "$0")
files=()
for f in *; do
    if [[ -f "$f" && "$f" != "$script_name" && "$f" != sort_log_*.txt ]]; then
        files+=("$f")
    fi
done

total_files=${#files[@]}

if [[ $total_files -eq 0 ]]; then
    echo -e "${BLUE}В директории нет подходящих файлов для сортировки.${NC}"
    exit 0
fi

echo -e "${BLUE}Начинаю фасовку ($total_files файлов) в режиме: $MODE${NC}"
echo "--- Сортировка начата: $(date) ---" > "$LOG_FILE"

current=0

# Основной цикл
for file in "${files[@]}"; do
    ((current++))

    # Извлекаем дату модификации файла
    if [[ "$MODE" == "flat" ]]; then
        dir_name=$(date -r "$file" "+%d-%m-%Y")
    else
        dir_name=$(date -r "$file" "+%Y/%m/%d")
    fi

    # Создаем папку и перемещаем файл
    mkdir -p "$dir_name"
    mv "$file" "$dir_name/"

    # Пишем в лог
    echo "[$(date '+%H:%M:%S')] Перемещен: '$file' -> '$dir_name/'" >> "$LOG_FILE"

    # Отрисовка прогресс-бара
    percent=$((current * 100 / total_files))
    filled=$((percent / 2)) # Бар длиной 50 символов
    empty=$((50 - filled))
    
    # Формируем строку бара (заполненная часть '#', пустая '-')
    bar=$(printf "%${filled}s" | tr ' ' '#')
    space=$(printf "%${empty}s" | tr ' ' '-')
    
    printf "\r${GREEN}[%s%s] %d%% (%d/%d)${NC}" "$bar" "$space" "$percent" "$current" "$total_files"
done

echo "--- Сортировка завершена: $(date) ---" >> "$LOG_FILE"
printf "\n${GREEN}Готово! Лог сохранен в: %s${NC}\n" "$LOG_FILE"