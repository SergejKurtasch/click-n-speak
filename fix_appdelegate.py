import sys

with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "r") as f:
    content = f.read()

old_switch = """        menuCtrl.onRuntimeRecoveryRequested = { [weak runtimeCoordinator] action in
            switch action {
            case .retry:
                runtimeCoordinator?.revalidateDesiredConfiguration(reason: .retry)
            case .keepPreviousRuntime:
                runtimeCoordinator?.keepPreviousRuntime(generation: action.generation)
            default:
                break
            }
        }"""
new_switch = """        menuCtrl.onRuntimeRecoveryRequested = { [weak runtimeCoordinator] action in
            switch action.kind {
            case .retry:
                runtimeCoordinator?.revalidateDesiredConfiguration(reason: .retry)
            case .keepPreviousRuntime:
                runtimeCoordinator?.keepPreviousRuntime(generation: action.generation)
            default:
                break
            }
        }"""
content = content.replace(old_switch, new_switch)

old_recovery = """                runtime.recoveryActions = recovery.compactMap {
                    MenuRuntimeRecoveryAction(rawValue: $0.rawValue)
                }"""
new_recovery = """                runtime.recoveryActions = recovery"""
content = content.replace(old_recovery, new_recovery)

with open("ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift", "w") as f:
    f.write(content)
