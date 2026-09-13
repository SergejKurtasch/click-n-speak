import sys
import re

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "r") as f:
    content = f.read()

def replace_in_func(func_name, old, new):
    global content
    pattern = r'(public func ' + func_name + r'.*?\{.*?\}[\n])'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        func_body = match.group(0)
        new_body = func_body.replace(old, new)
        content = content.replace(func_body, new_body)

replace_in_func('addManualTermValidated', 'try commit(candidate, promptLanguages: [LanguageCode.normalize(language)], invalidations: [.terms])', 'try commitTermMutation(candidate, languages: [LanguageCode.normalize(language)], invalidations: [.terms])')

replace_in_func('deleteTerm', 'try commit(candidate, promptLanguages: [lang], invalidations: [.terms])', 'try commitTermMutation(candidate, languages: [lang], invalidations: [.terms])')
replace_in_func('editTerm', 'try commit(candidate, promptLanguages: [lang], invalidations: [.terms])', 'try commitTermMutation(candidate, languages: [lang], invalidations: [.terms])')
replace_in_func('reactivateTerm', 'try commit(candidate, promptLanguages: [lang], invalidations: [.terms])', 'try commitTermMutation(candidate, languages: [lang], invalidations: [.terms])')
replace_in_func('importPromptText', 'try commit(candidate, promptLanguages: [lang], invalidations: [.terms])', 'try commitTermMutation(candidate, languages: [lang], invalidations: [.terms])')

replace_in_func('resolveSuggestions', 'try commit(candidate, promptLanguages: acceptedLanguages, invalidations: invalidations)', 'try commitTermMutation(candidate, languages: acceptedLanguages, invalidations: invalidations)')

old_addAll = """        try commit(
            candidate,
            promptLanguages: Set(pending.keys),
            invalidations: [.terms, .suggestions]
        )"""
new_addAll = """        try commitTermMutation(
            candidate,
            languages: Set(pending.keys),
            invalidations: [.terms, .suggestions]
        )"""
replace_in_func('addAllPendingSuggestions', old_addAll, new_addAll)

# runPromptAnalysis has a specific block
old_runPrompt = "            try commit(candidate, promptLanguages: Set(merged.keys), invalidations: [.terms, .suggestions])"
new_runPrompt = "            try commitTermMutation(candidate, languages: Set(merged.keys), invalidations: [.terms, .suggestions])"
replace_in_func('runPromptAnalysis', old_runPrompt, new_runPrompt)

with open("Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift", "w") as f:
    f.write(content)
