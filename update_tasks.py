with open("/Users/sergej/.gemini/antigravity/brain/9d5816f6-5190-4d3f-a773-7bb7fa2e42bc/task.md", "r") as f:
    content = f.read()

# I am working on "Block B — адресат команды восстановления"
content = content.replace("- [ ] Block B — адресат команды восстановления", "- [x] Block B — адресат команды восстановления")
content = content.replace("- [ ] Создать RuntimeRecoveryCommand, RuntimeRecoveryKind, RuntimeRecoveryTarget", "- [x] Создать RuntimeRecoveryCommand, RuntimeRecoveryKind, RuntimeRecoveryTarget")
content = content.replace("- [ ] Заменить app/UI recovery enums на новый тип. Создавать command из RuntimePreparationError", "- [x] Заменить app/UI recovery enums на новый тип. Создавать command из RuntimePreparationError")
content = content.replace("- [ ] Сравнивать generation с текущим владельцем перед восстановлением", "- [x] Сравнивать generation с текущим владельцем перед восстановлением")
content = content.replace("- [ ] Обрабатывать openAPIKeys (конкретный провайдер), download/redownload", "- [x] Обрабатывать openAPIKeys (конкретный провайдер), download/redownload")
content = content.replace("- [ ] Регрессии (OpenAI STT + отсутствующий Gemini editor и т.д.)", "- [x] Регрессии (OpenAI STT + отсутствующий Gemini editor и т.д.)")

with open("/Users/sergej/.gemini/antigravity/brain/9d5816f6-5190-4d3f-a773-7bb7fa2e42bc/task.md", "w") as f:
    f.write(content)
