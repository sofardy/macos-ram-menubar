# macos-ram-menubar

Нативная утилита для меню-бара macOS, которая показывает **реальную** загрузку RAM, состояние swap и топ процессов по памяти. Один Swift-файл, без внешних зависимостей.

## Что показывает

В баре — процент реально занятой памяти. По клику открывается меню:

- **Used / Total (%)** — реальная нагрузка = `App + Wired + Compressed` (то что нельзя освободить)
- **Available** — то, что система может отдать приложениям (`Free + Cached`)
- Разбивка: App, Wired, Compressed, Cached, Free
- **Swap** — использование (или "не используется")
- **Top processes by RAM** — топ-10 по RSS

> Зачем "реальная" цифра: macOS считает занятой почти всю память (включая дисковый кэш и компрессор), из-за чего Activity Monitor часто показывает 95-99%. Эта утилита показывает то, что нельзя освободить без свопа.

## Сборка

Нужен только `swiftc` (входит в Xcode Command Line Tools):

```bash
xcode-select --install   # если ещё не установлено
./build.sh
```

На выходе — `MenuBarMem.app` в текущей папке.

## Запуск

```bash
open MenuBarMem.app
```

Иконка чипа памяти появится в правой части меню-бара.

## Автозапуск при логине

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$PWD"'/MenuBarMem.app", hidden:false}'
```

## Технические детали

- `host_statistics64(HOST_VM_INFO64)` — статистика VM (free, active, wired, compressor, purgeable, internal/external pages)
- `sysctlbyname("hw.memsize")` — общий объём RAM
- `sysctlbyname("vm.swapusage")` — статистика swap
- `/bin/ps -axo pid=,rss=,comm=` — список процессов с RSS

Меню обновляется при каждом открытии, процент в баре — раз в 5 секунд.

## Требования

macOS 12+, Apple Silicon или Intel.
