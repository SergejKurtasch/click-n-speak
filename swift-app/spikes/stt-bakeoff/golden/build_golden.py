"""Build the STT bake-off golden dataset from phrases modelled on the user's
real Click-n-speak usage (dataset JSONL + user_terms + corrections).

Emits:
- manifest.jsonl   machine-readable: id, lang, text (ground-truth to speak),
                   text_norm (WER normalization), terms, bucket, tests
- READ_THESE.md    human reading script (id → phrase), grouped for recording

Language balance mirrors the logs (~85% Russian, ~14% Russian+embedded English
tech terms, ~1% pure English). Numbers are spelled out so the spoken form is
unambiguous. Run: python spikes/stt-bakeoff/golden/build_golden.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent

# lang tags: "ru" pure/light Russian, "ru+en" heavy code-switch, "en" English.
# bucket: "short" ≈1-2s, "medium" ≈2-8s (single chunk), "long" ≈>8s (multi-chunk).
# terms: dictionary/tech tokens present (for term-recall scoring).
PHRASES: list[dict] = [
    # ── short (1-2s) ────────────────────────────────────────────────────────
    {"id": "001", "lang": "ru", "bucket": "short", "text": "Останови запись."},
    {"id": "002", "lang": "ru", "bucket": "short", "text": "Открой лог-файл."},
    {"id": "003", "lang": "ru", "bucket": "short", "text": "Сделай коммит."},
    {"id": "004", "lang": "ru", "bucket": "short", "text": "Проверь тесты, пожалуйста."},

    # ── medium Russian, pure/light ──────────────────────────────────────────
    {"id": "005", "lang": "ru", "bucket": "medium",
     "text": "Прежде чем менять код, изучи все части проекта, где это может затрагиваться."},
    {"id": "006", "lang": "ru", "bucket": "medium",
     "text": "Извлеки текст из этих двух аудиофайлов и сохрани в отдельный документ."},
    {"id": "007", "lang": "ru", "bucket": "medium",
     "text": "Объясни ещё раз подробнее, что делает эта модель в ноутбуке."},
    {"id": "008", "lang": "ru", "bucket": "medium",
     "text": "Как на макбуке посмотреть, сколько осталось свободного места в настройках?"},
    {"id": "009", "lang": "ru", "bucket": "medium",
     "text": "Добавь обработку ошибок в эту функцию и напиши для неё тест."},
    {"id": "010", "lang": "ru", "bucket": "medium",
     "text": "Проверь орфографию и пунктуацию в этом абзаце, не меняя смысл."},
    {"id": "011", "lang": "ru", "bucket": "medium",
     "text": "Разбей эту большую функцию на несколько маленьких и понятных."},
    {"id": "012", "lang": "ru", "bucket": "medium",
     "text": "Почему сборка падает на этом шаге, и как это быстро починить?"},
    {"id": "013", "lang": "ru", "bucket": "medium",
     "text": "Сделай сводку встречи в три предложения для отправки коллегам."},
    {"id": "014", "lang": "ru", "bucket": "medium",
     "text": "Перепиши это предложение в активном залоге и покороче."},
    {"id": "015", "lang": "ru", "bucket": "medium",
     "text": "Мне нужно, чтобы сначала списывались бонусы, и только потом деньги с карты."},
    {"id": "016", "lang": "ru", "bucket": "medium",
     "text": "Составь план на завтра из пяти пунктов по приоритету."},
    {"id": "017", "lang": "ru", "bucket": "medium",
     "text": "Проверь, нет ли утечки памяти в этом цикле обработки."},
    {"id": "018", "lang": "ru", "bucket": "medium",
     "text": "Добавь логирование на каждый сетевой запрос и запись на диск."},
    {"id": "019", "lang": "ru", "bucket": "medium",
     "text": "Сформулируй три варианта заголовка для поста, покороче и без воды."},
    {"id": "020", "lang": "ru", "bucket": "medium",
     "text": "Помоги сделать коммит в текущей ветке, а потом создай новую ветку."},

    # ── medium Russian + one embedded tech term ─────────────────────────────
    {"id": "021", "lang": "ru", "bucket": "medium", "terms": ["cover letter"],
     "text": "Напиши короткое сопроводительное письмо, cover letter, для вакансии."},
    # terms must be listed AS THEY APPEAR in the phrase (term-recall does a
    # substring check on normalized text) — here Cyrillic "код-ревью", not "code review".
    {"id": "022", "lang": "ru", "bucket": "medium", "terms": ["код-ревью"],
     "text": "Проведи код-ревью последнего коммита и укажи самые критические ошибки."},
    {"id": "023", "lang": "ru", "bucket": "medium", "terms": ["LinkedIn"],
     "text": "Поправь эту рекомендацию с учётом того, что я публикую её на LinkedIn."},
    {"id": "024", "lang": "ru", "bucket": "medium", "terms": ["PDF"],
     "text": "Собери отчёт и выгрузи его в PDF одним файлом."},

    # ── medium Russian + heavy code-switch (multiple tech terms) ────────────
    {"id": "025", "lang": "ru", "bucket": "medium", "terms": ["GitHub"],
     "text": "Дай инструкции, как получить GitHub-токен для доступа к репозиторию."},
    {"id": "026", "lang": "ru+en", "bucket": "medium", "terms": ["Cognee", "MCP"],
     "text": "Есть ли у Cognee какой-то MCP-сервер, или в этом нет смысла?"},
    {"id": "027", "lang": "ru+en", "bucket": "medium", "terms": ["Initial", "Prompt", "Whisper"],
     "text": "Собери initial prompt из словаря терминов и передай его в Whisper."},
    {"id": "028", "lang": "ru", "bucket": "medium", "terms": ["survival", "C-Index"],
     "text": "Запусти survival-модель в трёх конфигурациях и сравни C-Index."},
    {"id": "029", "lang": "ru+en", "bucket": "medium", "terms": ["Whisper", "WhisperKit"],
     "text": "Сравни Whisper и WhisperKit по скорости и точности на русском."},
    {"id": "030", "lang": "ru+en", "bucket": "medium", "terms": ["Gemini", "API"],
     "text": "Оберни вызов Gemini API в таймаут и обработай ошибку сети."},
    {"id": "031", "lang": "ru", "bucket": "medium", "terms": ["readmission", "Checkpoints"],
     "text": "Новые pkl-файлы для обучения readmission-модели сохрани в папку Checkpoints."},
    {"id": "032", "lang": "ru", "bucket": "medium", "terms": ["Cursor", "Markdown"],
     "text": "Как в Cursor открыть предпросмотр Markdown-файла в красивом виде?"},
    {"id": "033", "lang": "ru", "bucket": "medium", "terms": ["LinkedIn", "HuggingFace"],
     "text": "Добавь LinkedIn и HuggingFace в словарь пользовательских терминов."},
    {"id": "034", "lang": "ru", "bucket": "medium", "terms": ["XGBoost", "Optuna"],
     "text": "Подбери гиперпараметры XGBoost через Optuna и сохрани лучшие."},

    # ── numbers spelled out ─────────────────────────────────────────────────
    {"id": "035", "lang": "ru", "bucket": "medium", "terms": ["survival"],
     "text": "Запусти триста пятьдесят прогонов survival-модели и сохрани результаты."},
    {"id": "036", "lang": "ru", "bucket": "medium",
     "text": "Исправь все ошибки, у которых оценка больше десяти, начиная с самых критических."},
    {"id": "037", "lang": "ru", "bucket": "medium",
     "text": "На макбуке эм-один покажи, сколько осталось свободного места в гигабайтах."},

    # ── long (multi-chunk) ──────────────────────────────────────────────────
    {"id": "038", "lang": "ru", "bucket": "long",
     "text": "Прежде чем вносить изменения, внимательно изучи всю структуру проекта, "
             "найди все места, где используется эта функция, и только потом аккуратно "
             "примени правки, ничего не сломав."},
    {"id": "039", "lang": "ru+en", "bucket": "long", "terms": ["merge request"],
     "text": "Я зашёл на GitLab, чтобы сделать merge request текущей ветки. "
             "Подскажи, что написать в title и в description на английском языке."},

    # ── pure English ────────────────────────────────────────────────────────
    {"id": "040", "lang": "en", "bucket": "medium", "terms": ["pull request"],
     "text": "Please review this pull request and suggest a shorter title."},
    {"id": "041", "lang": "en", "bucket": "medium", "terms": ["readmission"],
     "text": "Summarize the readmission model results in three bullet points."},
    {"id": "042", "lang": "en", "bucket": "medium", "terms": ["data scientist", "cover letter"],
     "text": "Generate a cover letter for a senior data scientist role."},
]


def normalize(text: str) -> str:
    """WER normalization: lowercase, ё→е, drop punctuation, collapse spaces.
    Hyphens between word parts become spaces (код-ревью → код ревью) since STT
    output rarely hyphenates. Numbers are already spelled out in the references.
    """
    t = text.lower().replace("ё", "е")
    t = t.replace("-", " ")
    t = re.sub(r"[^\w\s]", " ", t, flags=re.UNICODE)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def main() -> None:
    manifest = HERE / "manifest.jsonl"
    with manifest.open("w", encoding="utf-8") as f:
        for p in PHRASES:
            row = {
                "id": p["id"],
                "lang": p["lang"],
                "bucket": p["bucket"],
                "text": p["text"],
                "text_norm": normalize(p["text"]),
                "terms": p.get("terms", []),
                "audio": f"{p['id']}.wav",
            }
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    # Human reading script.
    lines = [
        "# Golden dataset — читать вслух и записывать\n",
        "Записывай **по одному файлу на фразу**. Имя файла = id (например `007.m4a`).",
        "Читай ровно то, что написано, в естественном темпе, с паузами на запятых.",
        "Не проговаривай знаки препинания. Ошибся — перезапиши файл заново.\n",
        "Английские термины произноси так, как ты обычно диктуешь их в работе.\n",
    ]
    by_bucket: dict[str, list[dict]] = {}
    for p in PHRASES:
        by_bucket.setdefault(p["bucket"], []).append(p)
    titles = {"short": "Короткие (1-2 сек)", "medium": "Средние (2-8 сек)", "long": "Длинные (>8 сек)"}
    for bucket in ("short", "medium", "long"):
        lines.append(f"\n## {titles[bucket]}\n")
        for p in by_bucket.get(bucket, []):
            tag = {"ru": "🇷🇺", "ru+en": "🇷🇺+🔤", "en": "🔤"}[p["lang"]]
            lines.append(f"**{p['id']}** {tag}  {p['text']}\n")
    (HERE / "READ_THESE.md").write_text("\n".join(lines), encoding="utf-8")

    # Stats.
    from collections import Counter
    langs = Counter(p["lang"] for p in PHRASES)
    buckets = Counter(p["bucket"] for p in PHRASES)
    with_terms = sum(1 for p in PHRASES if p.get("terms"))
    print(f"phrases: {len(PHRASES)}")
    print(f"by lang: {dict(langs)}")
    print(f"by bucket: {dict(buckets)}")
    print(f"with tech terms: {with_terms}")
    print(f"wrote {manifest} and READ_THESE.md")


if __name__ == "__main__":
    main()
