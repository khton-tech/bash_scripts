#!/bin/bash
#
# Утилита для сортировки файлов по дате (Flat).
# Версия: Brutal Fast (Zero Forks inside loop)

set -euo pipefail

TARGET_DIR="${1:-.}"
cd "$TARGET_DIR" || { echo "Ошибка: Не удалось перейти в $TARGET_DIR"; exit 1; }

script_name=$(basename "$0")

echo -e "\033[0;34mСобираем метаданные и начинаем фасовку...\033[0m"

count=0
bench_start=$(date +%s.%N)

# Кэш директорий, чтобы не дергать диск проверками [[ -d ... ]] для каждой папки
declare -A dirs_cache

# find -printf "%TY-%Tm-%Td\0%p\0" выдает потоком:
# ДАТА_ИЗМЕНЕНИЯ (NULL) ПУТЬ_К_ФАЙЛУ (NULL)
# Bash читает их мгновенно, не порождая новых процессов.
while IFS= read -r -d $'\0' file_date && IFS= read -r -d $'\0' filepath; do
    filename="${filepath#./}"
    
    # Исключаем себя
    [[ "$filename" == "$script_name" ]] && continue

    # Создаем папку, если ее еще нет (используем кэш в памяти)
    if [[ -z "${dirs_cache[$file_date]:-}" ]]; then
        [[ ! -d "$file_date" ]] && mkdir -p "$file_date"
        dirs_cache[$file_date]=1
    fi

    dest="$file_date/$filename"

    # Обработка коллизий (только встроенными средствами Bash)
    if [[ -e "$dest" ]]; then
        base="${filename%.*}"
        ext="${filename##*.}"
        [[ "$base" == "$ext" ]] && ext="" || ext=".$ext"
        
        c=1
        while [[ -e "$file_date/${base}_${c}${ext}" ]]; do ((c++)); done
        dest="$file_date/${base}_${c}${ext}"
    fi

    # Перенос файла
    mv "$filepath" "$dest"
    ((count++))

    # Обновляем прогресс-бар только раз на 1000 файлов (снижает I/O нагрузку терминала)
    if (( count % 1000 == 0 )); then
        echo -ne "\r\033[0;33mОбраработано файлов:\033[0m $count..."
    fi

done < <(find . -maxdepth 1 -type f -printf "%TY-%Tm-%Td\0%p\0")

# Финишные замеры
bench_end=$(date +%s.%N)
total_time=$(awk "BEGIN {printf \"%.2f\", $bench_end - $bench_start}")
avg_time=$(awk "BEGIN {if ($count > 0) printf \"%.5f\", $total_time / $count; else print 0}")

echo -e "\n\n\033[0;32m=== Готово! ===\033[0m"
echo "Обработано файлов: $count"
echo "Общее время: $total_time сек"
echo "Среднее время на файл: $avg_time сек"