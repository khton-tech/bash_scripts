#!/bin/bash
#
# Утилита для сортировки файлов по дате (Flat).
# Версия: Brutal Fast + Limit (-n)

set -euo pipefail

TARGET_DIR="."
FILE_LIMIT=0

# Вернули парсинг аргументов
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--files) FILE_LIMIT="${2:-0}"; shift ;;
        -t|--target) TARGET_DIR="${2:-.}"; shift ;;
        *) echo -e "\033[0;31mНеизвестный параметр: $1\033[0m"; exit 1 ;;
    esac
    shift
done

cd "$TARGET_DIR" || { echo "Ошибка: Не удалось перейти в $TARGET_DIR"; exit 1; }
script_name=$(basename "$0")

echo -e "\033[0;34mСобираем метаданные и начинаем фасовку...\033[0m"

count=0
bench_start=$(date +%s.%N)
declare -A dirs_cache

# Читаем поток от find
while IFS= read -r -d $'\0' file_date && IFS= read -r -d $'\0' filepath; do
    filename="${filepath#./}"
    
    [[ "$filename" == "$script_name" ]] && continue

    if [[ -z "${dirs_cache[$file_date]:-}" ]]; then
        [[ ! -d "$file_date" ]] && mkdir -p "$file_date"
        dirs_cache[$file_date]=1
    fi

    dest="$file_date/$filename"

    if [[ -e "$dest" ]]; then
        base="${filename%.*}"
        ext="${filename##*.}"
        [[ "$base" == "$ext" ]] && ext="" || ext=".$ext"
        
        c=1
        while [[ -e "$file_date/${base}_${c}${ext}" ]]; do ((c++)); done
        dest="$file_date/${base}_${c}${ext}"
    fi

    mv "$filepath" "$dest"
    ((count++))

    if (( count % 1000 == 0 )); then
        echo -ne "\r\033[0;33mОбраработано файлов:\033[0m $count..."
    fi

    # Жесткий стоп по лимиту
    if [[ "$FILE_LIMIT" -gt 0 && "$count" -ge "$FILE_LIMIT" ]]; then
        break
    fi

# 2>/dev/null нужен, чтобы find не ругался на "Broken pipe", когда мы делаем break
done < <(find . -maxdepth 1 -type f -printf "%TY-%Tm-%Td\0%p\0" 2>/dev/null)

bench_end=$(date +%s.%N)
total_time=$(awk "BEGIN {printf \"%.2f\", $bench_end - $bench_start}")
avg_time=$(awk "BEGIN {if ($count > 0) printf \"%.5f\", $total_time / $count; else print 0}")

echo -e "\n\n\033[0;32m=== Готово! ===\033[0m"
echo "Обработано файлов: $count"
echo "Общее время: $total_time сек"
echo "Среднее время на файл: $avg_time сек"