import CNSDictionary
import CNSCore
import CNSTranscription

enum UIErrorLocalization {
    static func dictionary(_ error: Error, i18n: I18n) -> String {
        guard let error = error as? DictionaryCoordinatorError else {
            return i18n.t("ui.error_persistence")
        }
        switch error {
        case .invalidTerm: return i18n.t("ui.error_invalid_term")
        case .duplicateTerm: return i18n.t("ui.error_duplicate_term")
        case .termNotFound: return i18n.t("ui.error_missing_term")
        case .suggestionNotFound: return i18n.t("ui.error_missing_suggestion")
        case .noSnapshot: return i18n.t("ui.error_no_snapshot")
        case .invalidReplacement: return i18n.t("ui.error_invalid_replacement")
        case .conflictingReplacement: return i18n.t("ui.error_conflicting_replacement")
        case .persistenceRollbackFailed: return i18n.t("ui.error_persistence")
        }
    }

    static func transcription(_ failure: TranscriptionFailure, i18n: I18n) -> String {
        let key: String
        switch failure.kind {
        case .unavailable, .modelLoad:
            key = "dialog.file_failure_unavailable"
        case .unauthorized:
            key = "dialog.file_failure_authorization"
        case .rateLimited:
            key = "dialog.file_failure_rate_limited"
        case .server, .network, .retryExhausted:
            key = "dialog.file_failure_network"
        case .unsupportedMedia:
            key = "dialog.file_failure_unsupported"
        case .decode, .fileDecode, .malformedResponse:
            key = "dialog.file_failure_decode"
        case .invalidRequest, .unknown:
            key = "dialog.file_failure_generic"
        }
        return i18n.t(key)
    }
}
