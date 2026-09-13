import json
import sys

# English
with open("locales/en.json", "r") as f:
    en_data = json.load(f)

en_data["state.deleting"] = "Deleting..."
en_data["state.downloading"] = "Downloading..."
en_data["state.preparing"] = "Preparing..."
en_data["state.in_use"] = "In use"
en_data["dialog.delete_failed_title"] = "Delete failed"

with open("locales/en.json", "w") as f:
    json.dump(en_data, f, indent=4, ensure_ascii=False)

# Russian
with open("locales/ru.json", "r") as f:
    ru_data = json.load(f)

# Wait, I added it to Russian already? Let's verify
if "state.deleting" not in ru_data:
    ru_data["state.deleting"] = "Удаляется"
if "state.downloading" not in ru_data:
    ru_data["state.downloading"] = "Загружается/проверяется"
if "state.preparing" not in ru_data:
    ru_data["state.preparing"] = "Готовится"
if "state.in_use" not in ru_data:
    ru_data["state.in_use"] = "Используется"
if "dialog.delete_failed_title" not in ru_data:
    ru_data["dialog.delete_failed_title"] = "Ошибка удаления"

with open("locales/ru.json", "w") as f:
    json.dump(ru_data, f, indent=4, ensure_ascii=False)

