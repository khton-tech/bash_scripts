#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import time
import random
import argparse
import subprocess
import ctypes
from datetime import datetime

# --- Магия ctypes для прямого вызова системных часов (без форков) ---
CLOCK_REALTIME = 0
class timespec(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]

try:
    libc = ctypes.CDLL('libc.so.6')
except OSError:
    libc = None

def set_system_time(timestamp):
    """Меняет системное время через прямой вызов ядра Линукса"""
    if not libc:
        return
    ts = timespec()
    ts.tv_sec = int(timestamp)
    ts.tv_nsec = 0
    libc.clock_settime(CLOCK_REALTIME, ctypes.byref(ts))

def parse_date(date_str):
    return int(datetime.strptime(date_str, "%Y-%m-%d").timestamp())

def main():
    parser = argparse.ArgumentParser(description="Мок-генератор файлов на максималках")
    parser.add_argument("-c", "--count", type=int, default=200)
    parser.add_argument("-ds", "--date-start", default="2023-01-01")
    parser.add_argument("-de", "--date-end", default="2024-01-01")
    parser.add_argument("-dc", "--date-create", action="store_true")
    parser.add_argument("-sm", "--size-min", type=int, default=1)
    parser.add_argument("-sx", "--size-max", type=int, default=5)
    parser.add_argument("-f", "--folders", action="store_true")
    parser.add_argument("-d", "--depth", type=int, default=3)
    parser.add_argument("-t", "--target", default="./mock_data")
    
    args = parser.parse_args()

    start_ts = parse_date(args.date_start)
    end_ts = parse_date(args.date_end)
    
    if end_ts < start_ts:
        print("\033[31mОшибка: Конечная дата должна быть больше начальной!\033[0m")
        sys.exit(1)

    diff = end_ts - start_ts

    if args.date_create:
        if os.geteuid() != 0:
            print("\033[31mОшибка: Для хардкорной подмены даты (-dc) нужны права root (sudo)!\033[0m")
            sys.exit(1)
        print("\033[33mВНИМАНИЕ: Активирована Машина времени. Отключаем NTP...\033[0m")
        subprocess.run(["timedatectl", "set-ntp", "false"], check=False)

    os.makedirs(args.target, exist_ok=True)
    print(f"Начинаем генерацию {args.count} файлов в '{args.target}'...")

    bench_start = time.perf_counter()

    try:
        for i in range(1, args.count + 1):
            # Вся математика выполняется мгновенно в памяти
            rand_size_bytes = random.randint(args.size_min, args.size_max) * 1024 * 1024
            rand_ts = start_ts + random.randint(0, diff)
            
            current_dir = args.target
            if args.folders:
                depth = random.randint(1, args.depth)
                # Быстрая генерация пути без циклов
                subdirs = [f"dir_{random.randint(1, 5)}" for _ in range(depth)]
                current_dir = os.path.join(args.target, *subdirs)
                os.makedirs(current_dir, exist_ok=True)
            
            file_path = os.path.join(current_dir, f"file_{rand_ts}_{i}.log")

            # --- ПРЫЖОК ВО ВРЕМЕНИ ---
            if args.date_create:
                set_system_time(rand_ts)
            
            # --- СОЗДАНИЕ ФАЙЛА ---
            # Используем posix_fallocate (эквивалент утилиты fallocate) - аллоцирует место мгновенно
            fd = os.open(file_path, os.O_CREAT | os.O_WRONLY)
            try:
                os.posix_fallocate(fd, 0, rand_size_bytes)
            except OSError:
                # Fallback, если ФС (например, tmpfs) не поддерживает fallocate
                os.write(fd, b'\0' * rand_size_bytes)
            os.close(fd)

            # Если мы не меняли системное время, подменяем mtime/atime обычным способом
            if not args.date_create:
                os.utime(file_path, (rand_ts, rand_ts))

            if i % 100 == 0:
                sys.stdout.write(f"\r\033[36mСгенерировано {i} из {args.count} файлов...\033[0m")
                sys.stdout.flush()

    finally:
        # Блок finally работает как trap в bash - выполнится 100% при любом исходе
        if args.date_create:
            print("\n\033[33mВозвращаем время в норму (NTP)...\033[0m")
            subprocess.run(["timedatectl", "set-ntp", "true"], check=False)
            time.sleep(2)
            print(f"\033[32mТекущее время восстановлено: {datetime.now()}\033[0m")

    bench_end = time.perf_counter()
    print("\n=== Готово! ===")
    print(f"Затрачено времени: {bench_end - bench_start:.2f} сек")

if __name__ == "__main__":
    main()