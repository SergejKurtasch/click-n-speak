import json
import glob
import os

keys = {
    "terms.conflict_changed": "Term changed elsewhere",
    "terms.conflict_deleted": "Term deleted elsewhere",
    "terms.add_as_new": "Add as new",
    "terms.load_saved": "Load saved",
    "terms.discard": "Discard"
}

ru_keys = {
    "terms.conflict_changed": "Термин изменён в другом месте",
    "terms.conflict_deleted": "Термин удалён в другом месте",
    "terms.add_as_new": "Добавить как новый",
    "terms.load_saved": "Загрузить сохранённое",
    "terms.discard": "Отменить"
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
