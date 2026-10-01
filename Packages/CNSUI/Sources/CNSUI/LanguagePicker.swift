import AppKit
import SwiftUI
import CNSCore

@MainActor
public final class LanguagePicker: NSWindow, NSWindowDelegate {
    private let onConfigChanged: (Config) -> Void
    private let onCancelled: () -> Void
    private var saved = false

    public init(
        config: Config,
        i18n: I18n,
        onConfigChanged: @escaping (Config) -> Void,
        onCancelled: @escaping () -> Void = {}
    ) {
        self.onConfigChanged = onConfigChanged
        self.onCancelled = onCancelled
        super.init(contentRect: NSRect(x: 0, y: 0, width: 450, height: 500),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered,
                   defer: false)
        self.title = i18n.t("menu.languages")
        self.delegate = self
        self.minSize = NSSize(width: 400, height: 450)
        self.isReleasedWhenClosed = false

        let vc = NSHostingController(
            rootView: LanguagePickerView(
                config: config,
                i18n: i18n,
                onSave: { [weak self] updated in
                    guard let self else { return }
                    self.saved = true
                    self.onConfigChanged(updated)
                    self.close()
                }
            )
        )
        self.contentViewController = vc
        self.center()
    }

    public func windowWillClose(_ notification: Notification) {
        if !saved {
            onCancelled()
        }
    }
}

struct LanguagePickerView: View {
    @StateObject private var vm: LanguagePickerViewModel
    let onSave: (Config) -> Void

    init(config: Config, i18n: I18n, onSave: @escaping (Config) -> Void) {
        self.onSave = onSave
        _vm = StateObject(wrappedValue: LanguagePickerViewModel(config: config, i18n: i18n))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(vm.i18n.t("language_picker.title"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(vm.i18n.t("language_picker.help"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Form {
                Picker(vm.i18n.t("language_picker.primary"), selection: $vm.primary) {
                    ForEach(vm.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("language-picker.primary")
                .onChange(of: vm.primary) { _, _ in
                    vm.additional.remove(vm.primary)
                }

                Section(header: Text(vm.i18n.t("language_picker.additional")).font(.subheadline)) {
                    List(vm.availableLanguages.filter { $0.code != vm.primary }, id: \.code) { lang in
                        Toggle(lang.name, isOn: Binding(
                            get: { vm.additional.contains(lang.code) },
                            set: { isSet in
                                if isSet {
                                    vm.additional.insert(lang.code)
                                } else {
                                    vm.additional.remove(lang.code)
                                }
                            }
                        ))
                        .accessibilityIdentifier("language-picker.additional.\(lang.code)")
                    }
                    .frame(height: 250)
                    .border(Color.secondary.opacity(0.2))
                }

                Toggle(vm.i18n.t("language_picker.auto_detect"), isOn: $vm.autoDetect)
                    .accessibilityIdentifier("language-picker.auto-detect")
            }
            .padding()

            HStack {
                Button(vm.i18n.t("btn.cancel")) {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(vm.i18n.t("btn.save")) {
                    vm.save()
                    onSave(vm.config)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("language-picker.save")
            }
            .padding(.bottom)
        }
        .frame(minWidth: 400, minHeight: 450)
    }
}

class LanguagePickerViewModel: ObservableObject {
    var config: Config
    let i18n: I18n

    @Published var primary: String
    @Published var additional: Set<String>
    @Published var autoDetect: Bool

    struct Lang: Identifiable, Equatable {
        let code: String
        let name: String
        var id: String { code }
    }

    let availableLanguages: [Lang]

    init(config: Config, i18n: I18n) {
        self.config = config
        self.i18n = i18n

        let supported = Set(Self.supportedCodes)
        let configuredPrimary = LanguageCode.normalize(config.primaryLanguage)
        let validatedPrimary = supported.contains(configuredPrimary) ? configuredPrimary : "en"
        self.primary = validatedPrimary
        self.additional = Set(LanguageCode.dedupeList(
            config.additionalLanguages.filter { supported.contains(LanguageCode.normalize($0)) },
            primary: validatedPrimary
        ))
        self.autoDetect = config.raw["language_auto_detect"]?.boolValue ?? false

        self.availableLanguages = Self.supportedCodes.map {
            Lang(code: $0, name: LanguageCode.displayNames[$0] ?? $0.uppercased())
        }
    }

    func save() {
        let validatedPrimary = Self.supportedCodes.contains(primary) ? primary : "en"
        let desiredAdditional = Self.supportedCodes.filter {
            $0 != validatedPrimary && additional.contains($0)
        }
        var updated = LanguageSettings.selectPrimary(validatedPrimary, in: config)
        for language in updated.additionalLanguages where !desiredAdditional.contains(language) {
            updated = LanguageSettings.toggleAdditional(language, in: updated)
        }
        for language in desiredAdditional where !updated.additionalLanguages.contains(language) {
            updated = LanguageSettings.toggleAdditional(language, in: updated)
        }
        updated = LanguageSettings.setAutoDetect(autoDetect, in: updated)
        updated.raw["language_picker_done"] = .bool(true)
        config = updated
    }

    private static let supportedCodes = ["ru", "en", "uk", "de", "es", "fr"]
}
