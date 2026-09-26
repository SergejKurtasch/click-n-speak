import json
import glob
import os

keys = {
    "stats.loading": "Loading statistics...",
    "stats.failed": "Failed to load statistics."
}

ru_keys = {
    "stats.loading": "Загрузка статистики...",
    "stats.failed": "Не удалось получить статистику."
}

for path in glob.glob("locales/*.json"):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if "ru" in path or "uk" in path:
        data.update(ru_keys)
    else:
        data.update(keys)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
