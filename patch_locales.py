import json
import glob
import os

locales = {
    "en": {
        "dialog.credential_env_override": "Key is provided by environment variable %@. To change it, restart the app with a different environment.",
        "dialog.credential_saved": "Key saved. Availability will be checked upon next use."
    },
    "ru": {
        "dialog.credential_env_override": "Ключ задан переменной окружения %@. Для изменения перезапустите приложение с новым окружением.",
        "dialog.credential_saved": "Ключ сохранён. Работоспособность проверяется при обращении к сервису."
    }
}

for filepath in glob.glob("locales/*.json"):
    lang = os.path.basename(filepath).split(".")[0]
    with open(filepath, "r") as f:
        data = json.load(f)
    
    keys = locales.get(lang, locales["en"])
    data.update(keys)
    
    with open(filepath, "w") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")
