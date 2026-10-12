import Testing
@testable import CNSTranscription

@Suite("HallucinationFilter")
struct HallucinationFilterTests {
    let filter = HallucinationFilter()

    @Test("Phrase-list hallucinations are dropped (final and non-final)")
    func phraseDrop() {
        #expect(filter.filter("Thank you", isFinal: false) == "")
        #expect(filter.filter("Thank you", isFinal: true) == "")
        // "субтитры" as a standalone word matches the phrase list → dropped.
        #expect(filter.filter("включи субтитры", isFinal: false) == "")
    }

    @Test("Word-boundary prevents substring false positives")
    func wordBoundary() {
        // "субтитрышка" contains "субтитры" as a substring but not as a word.
        #expect(filter.filter("субтитрышка тут", isFinal: false) == "субтитрышка тут")
    }

    @Test("Suspicious CJK dropped only for non-final")
    func cjk() {
        let cjk = "这是中文文本内容"
        #expect(filter.filter(cjk, isFinal: false) == "")
        #expect(filter.filter(cjk, isFinal: true) == cjk)
    }

    @Test("Single-word you/the dropped only for non-final")
    func singleWord() {
        #expect(filter.filter("You.", isFinal: false) == "")
        #expect(filter.filter("the", isFinal: false) == "")
        #expect(filter.filter("You.", isFinal: true) == "You")  // kept, dots stripped
    }

    @Test("Consecutive word repetition collapses (matches Python)")
    func collapse() {
        #expect(filter.collapseConsecutiveWordRepetition("купить машину. Машину красного")
                == "купить машину. красного")
        #expect(filter.collapseConsecutiveWordRepetition("go go go home") == "go home")
    }

    @Test("Subword repetition stripped to a single unit")
    func subword() {
        #expect(filter.filter("oiseoiseoiseoiseoiseoise", isFinal: false) == "oise")
        #expect(filter.filter("ftaftaftaftaftafta", isFinal: false) == "fta")
    }

    @Test("Emphasis like ха-ха-ха is not over-collapsed")
    func emphasis() {
        #expect(filter.filter("ха-ха-ха", isFinal: false) == "ха-ха-ха")
    }

    @Test("Normal text passes through, dots trimmed")
    func passthrough() {
        #expect(filter.filter("hello world", isFinal: false) == "hello world")
        #expect(filter.filter("… привет.", isFinal: true) == "привет")
    }

    @Test("Whole chunk prompt echoes are dropped completely")
    func promptEchoWholeChunk() {
        #expect(filter.filter("English language", isFinal: true) == "")
        #expect(filter.filter("English language.", isFinal: true) == "")
        #expect(filter.filter("Русский язык", isFinal: true) == "")
        #expect(filter.filter("Русский язык.", isFinal: true) == "")
        #expect(filter.filter("Русский язык, Русский язык", isFinal: true) == "")
        #expect(filter.filter("Это разговорная речь.", isFinal: true) == "")
        #expect(filter.filter("Это разговорная речь. Используются профессиональные термины и аббревиатуры.", isFinal: true) == "")
    }

    @Test("Prompt language hints at boundaries are stripped")
    func promptEchoBoundaries() {
        let sentenceWithEnglishTail = "Если пользователь захочет собирать аппликейшн, то ему нужен установленный x код на макбуке English language"
        #expect(filter.filter(sentenceWithEnglishTail, isFinal: true) == "Если пользователь захочет собирать аппликейшн, то ему нужен установленный x код на макбуке")

        let withPeriod = "x код на макбуке English language."
        #expect(filter.filter(withPeriod, isFinal: true) == "x код на макбуке")

        let leadingRussian = "Русский язык Посмотри на текущее состояние"
        #expect(filter.filter(leadingRussian, isFinal: true) == "Посмотри на текущее состояние")

        let leadingRussianWithDot = "Русский язык. Оставь все как есть."
        #expect(filter.filter(leadingRussianWithDot, isFinal: true) == "Оставь все как есть")
    }

    @Test("Legitimate occurrences with prepositions are preserved")
    func legitimateLanguagePhrasesPreserved() {
        #expect(filter.filter("Переведи на русский язык", isFinal: true) == "Переведи на русский язык")
        #expect(filter.filter("Переведи финальную версию на русский язык.", isFinal: true) == "Переведи финальную версию на русский язык")
    }
}

@Suite("AudioGuards")
struct AudioGuardsTests {
    @Test("Tiny final chunk is skipped")
    func tinyFinal() {
        let samples = [Float](repeating: 0.1, count: 8000)
        #expect(AudioGuards.skipReason(sampleCount: 8000, samples: samples, isFinal: true) == .tinyFinalChunk)
        // Above the threshold is fine.
        let bigger = [Float](repeating: 0.1, count: 8001)
        #expect(AudioGuards.skipReason(sampleCount: 8001, samples: bigger, isFinal: true) == nil)
    }

    @Test("Silent short final chunk is skipped")
    func silentShortFinal() {
        let quiet = [Float](repeating: 0.001, count: 10115) // ~0.63s silence
        #expect(AudioGuards.skipReason(sampleCount: 10115, samples: quiet, isFinal: true) == .silentShortChunk)
    }

    @Test("Silent short non-final chunk is skipped")
    func silentShort() {
        let quiet = [Float](repeating: 0.001, count: 16000) // 1s, rms 0.001 < 0.005
        #expect(AudioGuards.skipReason(sampleCount: 16000, samples: quiet, isFinal: false) == .silentShortChunk)
    }

    @Test("Loud short non-final chunk proceeds")
    func loudShort() {
        let loud = [Float](repeating: 0.1, count: 16000)
        #expect(AudioGuards.skipReason(sampleCount: 16000, samples: loud, isFinal: false) == nil)
    }

    @Test("Long chunk proceeds even if quiet")
    func longQuiet() {
        let quiet = [Float](repeating: 0.001, count: 48000) // exactly 3s, not < shortChunk
        #expect(AudioGuards.skipReason(sampleCount: 48000, samples: quiet, isFinal: false) == nil)
    }

    @Test("isSilent threshold")
    func silent() {
        #expect(AudioGuards.isSilent([Float](repeating: 0.001, count: 100)) == true)
        #expect(AudioGuards.isSilent([Float](repeating: 0.01, count: 100)) == false)
    }
}
