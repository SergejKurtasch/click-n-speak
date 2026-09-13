import json
import os

locales = {
    "en": {
        "terms.undo_prompt": "Revert language:",
        "ui.error_no_snapshot": "No saved state to revert to."
    },
    "ru": {
        "terms.undo_prompt": "Язык отката:",
        "ui.error_no_snapshot": "Нет сохранённого состояния для отката."
    },
    "de": {
        "terms.undo_prompt": "Sprache rückgängig machen:",
        "ui.error_no_snapshot": "Kein gespeicherter Zustand zum Rückgängigmachen."
    },
    "fr": {
        "terms.undo_prompt": "Annuler la langue :",
        "ui.error_no_snapshot": "Aucun état enregistré à annuler."
    },
    "es": {
        "terms.undo_prompt": "Revertir idioma:",
        "ui.error_no_snapshot": "No hay un estado guardado para revertir."
    },
    "uk": {
        "terms.undo_prompt": "Мова скасування:",
        "ui.error_no_snapshot": "Немає збереженого стану для скасування."
    }
}

for lang, additions in locales.items():
    path = f"locales/{lang}.json"
    if os.path.exists(path):
        with open(path, "r") as f:
            data = json.load(f)
        data.update(additions)
        with open(path, "w") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write("\n")
