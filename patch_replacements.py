import sys

with open("Packages/CNSUI/Sources/CNSUI/ReplacementsPanel.swift", "r") as f:
    content = f.read()

content = content.replace("public func refresh() { viewModel.load(resetDrafts: true) }", "public func refresh() { viewModel.load() }")
content = content.replace("public func refreshForPresentation() { refresh() }", "public func refreshForPresentation() { refresh() }")

old_load = """    func load(resetDrafts: Bool = false) {
        sections = coordinator.replacementSections()
        if resetDrafts {
            fromDrafts.removeAll()
            toDrafts.removeAll()
        }
        for row in sections.active where row.source == "manual" {
            if fromDrafts[row.id] == nil { fromDrafts[row.id] = row.from }
            if toDrafts[row.id] == nil { toDrafts[row.id] = row.to }
        }
    }"""
new_load = """    func load() {
        sections = coordinator.replacementSections()
        for row in sections.active where row.source == "manual" {
            if fromDrafts[row.id] == nil { fromDrafts[row.id] = row.from }
            if toDrafts[row.id] == nil { toDrafts[row.id] = row.to }
        }
    }"""
content = content.replace(old_load, new_load)
content = content.replace("load(resetDrafts: true)", "load()")

# Update perform to not reset drafts, but maybe we only reset for saved?
# "очищать только сохранённую строку"
old_perform = """    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            load(resetDrafts: true)
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }"""
new_perform = """    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            load()
        } catch {
            errorMessage = UIErrorLocalization.dictionary(error, i18n: i18n)
        }
    }"""
content = content.replace(old_perform, new_perform)

# Update save to clear draft
old_save = """    func save(_ row: ReplacementRow) {
        let edited = (fromDrafts[row.id] ?? row.from, toDrafts[row.id] ?? row.to)
        let replacements = sections.active.filter { $0.source == "manual" }.map { current in
            current.id == row.id ? edited : (current.from, current.to)
        }
        perform { try coordinator.saveManualReplacements(replacements) }
    }"""
new_save = """    func save(_ row: ReplacementRow) {
        let edited = (fromDrafts[row.id] ?? row.from, toDrafts[row.id] ?? row.to)
        let replacements = sections.active.filter { $0.source == "manual" }.map { current in
            current.id == row.id ? edited : (current.from, current.to)
        }
        perform { 
            try coordinator.saveManualReplacements(replacements)
            fromDrafts.removeValue(forKey: row.id)
            toDrafts.removeValue(forKey: row.id)
        }
    }"""
content = content.replace(old_save, new_save)

with open("Packages/CNSUI/Sources/CNSUI/ReplacementsPanel.swift", "w") as f:
    f.write(content)
