#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Утилита для сортировки файлов (Flat).
# Версия: Brutal Fast Python (Date Create + Fallback)

import os
import sys
import time
import argparse
from datetime import datetime

def main():
    parser = argparse.ArgumentParser(description="Ультра-быстрая сортировка файлов.")
    parser.add_argument("-n", "--files", type=int, default=0, help="Лимит файлов")
    parser.add_argument("-t", "--target", type=str, default=".", help="Целевая директория")
    args = parser.parse_args()

    target_dir = args.target
    file_limit = args.files
    script_name = os.path.basename(__file__)

    if not os.path.isdir(target_dir):
        print(f"\033[0;31mОшибка: Директория {target_dir} не найдена.\033[0m")
        sys.exit(1)

    print("\033[0;34m[Python] Собираем метаданные (Дата создания) и начинаем фасовку...\033[0m")

    count = 0
    dirs_cache = set()
    bench_start = time.perf_counter()

    try:
        with os.scandir(target_dir) as it:
            for entry in it:
                if not entry.is_file():
                    continue
                
                if entry.name == script_name:
                    continue

                stat_info = entry.stat()
                
                # --- ЛОГИКА ПОЛУЧЕНИЯ ДАТЫ СОЗДАНИЯ ---
                try:
                    if sys.platform == 'win32':
                        # В Windows st_ctime — это дата создания
                        ts = stat_info.st_ctime
                    else:
                        # В современных Linux и macOS это st_birthtime
                        ts = stat_info.st_birthtime
                except AttributeError:
                    # Если старый Linux или ФС не поддерживает birthtime,
                    # делаем fallback на дату изменения (mtime), как было в Баше
                    ts = stat_info.st_mtime
                # ----------------------------------------

                date_str = datetime.fromtimestamp(ts).strftime('%Y-%m-%d')
                
                dest_dir = os.path.join(target_dir, date_str)

                if dest_dir not in dirs_cache:
                    os.makedirs(dest_dir, exist_ok=True)
                    dirs_cache.add(dest_dir)

                dest_path = os.path.join(dest_dir, entry.name)

                if os.path.exists(dest_path):
                    base, ext = os.path.splitext(entry.name)
                    c = 1
                    while True:
                        new_name = f"{base}_{c}{ext}"
                        dest_path = os.path.join(dest_dir, new_name)
                        if not os.path.exists(dest_path):
                            break
                        c += 1

                os.rename(entry.path, dest_path)
                count += 1

                if count % 1000 == 0:
                    sys.stdout.write(f"\r\033[0;33mОбработано файлов:\033[0m {count}...")
                    sys.stdout.flush()

                if 0 < file_limit <= count:
                    break

    except KeyboardInterrupt:
        print("\n\033[0;31mПрервано пользователем.\033[0m")
        sys.exit(2)
    except Exception as e:
        print(f"\n\033[0;31mКритическая ошибка: {e}\033[0m")
        sys.exit(1)

    bench_end = time.perf_counter()
    total_time = bench_end - bench_start
    avg_time = total_time / count if count > 0 else 0

    print(f"\n\n\033[0;32m=== Готово! ===\033[0m")
    print(f"Обработано файлов: {count}")
    print(f"Общее время: {total_time:.4f} сек")
    print(f"Среднее время на файл: {avg_time:.6f} сек")

if __name__ == "__main__":
    main()