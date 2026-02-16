import Foundation

public struct SmartSentenceSplitter {
    
    // Common abbreviations that shouldn't trigger sentence splits
    private static let abbreviations: Set<String> = [
        "Dr", "Mr", "Mrs", "Ms", "Prof", "Rev", "Hon",
        "U.S", "U.K", "U.N", "E.U", "NASA", "FBI", "CIA",
        "Inc", "Corp", "Ltd", "Co", "LLC",
        "St", "Ave", "Blvd", "Rd", "Mt", "Ft",
        "Jan", "Feb", "Mar", "Apr", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
        "vs", "etc", "i.e", "e.g", "a.m", "p.m"
    ]
    
    public static func splitIntoSentences(_ text: String, minWordsPerSentence: Int = 5) -> [String] {
        // Clean and normalize the text
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        // If text is short enough, return as single sentence
        let wordCount = cleanText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        if wordCount <= minWordsPerSentence + 2 {
            return [cleanText]
        }
        
        // Split by sentence-ending punctuation
        var sentences = preliminarySplit(cleanText)
        
        // Filter out abbreviation false positives
        sentences = filterAbbreviations(sentences)
        
        // Combine short sentences with next sentence
        sentences = combineShortSentences(sentences, minWords: minWordsPerSentence)
        
        // Final cleanup
        sentences = sentences.compactMap { sentence in
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        
        return sentences.isEmpty ? [cleanText] : sentences
    }
    
    private static func preliminarySplit(_ text: String) -> [String] {
        // Split on sentence endings: . ! ? with optional quotes/parentheses
        let pattern = #"([.!?]+[\s]*[\)\]"']*)\s+"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        
        var sentences: [String] = []
        var lastRange = text.startIndex
        
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        for match in matches {
            let range = Range(match.range, in: text)!
            let sentence = String(text[lastRange..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            lastRange = range.upperBound
        }
        
        // Add remaining text if any
        if lastRange < text.endIndex {
            let remaining = String(text[lastRange...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }
        }
        
        return sentences.isEmpty ? [text] : sentences
    }
    
    private static func filterAbbreviations(_ sentences: [String]) -> [String] {
        var filteredSentences: [String] = []
        var i = 0
        
        while i < sentences.count {
            let current = sentences[i]
            
            // Check if this "sentence" ends with a likely abbreviation
            if i < sentences.count - 1 && looksLikeAbbreviation(current) {
                // Combine with next sentence
                let combined = current + " " + sentences[i + 1]
                filteredSentences.append(combined)
                i += 2 // Skip the next sentence since we combined it
            } else {
                filteredSentences.append(current)
                i += 1
            }
        }
        
        return filteredSentences
    }
    
    private static func looksLikeAbbreviation(_ sentence: String) -> Bool {
        // Extract the last "word" before the period
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: .whitespacesAndNewlines)
        
        guard let lastWord = components.last else { return false }
        
        // Remove trailing punctuation to get the base word
        let baseWord = lastWord.trimmingCharacters(in: .punctuationCharacters)
        
        // Check against known abbreviations
        if abbreviations.contains(baseWord) {
            return true
        }
        
        // Heuristics for abbreviation detection
        if baseWord.count <= 4 && baseWord.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            return true
        }
        
        // Single letter followed by period (A. B. C.)
        if baseWord.count == 1 && baseWord.first?.isLetter == true {
            return true
        }
        
        return false
    }
    
    private static func combineShortSentences(_ sentences: [String], minWords: Int) -> [String] {
        var combinedSentences: [String] = []
        var currentSentence = ""
        var currentWordCount = 0
        
        for sentence in sentences {
            let wordCount = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            
            if currentSentence.isEmpty {
                // Start new sentence
                currentSentence = sentence
                currentWordCount = wordCount
            } else if currentWordCount < minWords && currentWordCount + wordCount <= minWords * 2 {
                // Combine with current sentence if it's still reasonable length
                currentSentence += " " + sentence
                currentWordCount += wordCount
            } else {
                // Current sentence is good, save it and start new one
                combinedSentences.append(currentSentence)
                currentSentence = sentence
                currentWordCount = wordCount
            }
        }
        
        // Add the last sentence
        if !currentSentence.isEmpty {
            combinedSentences.append(currentSentence)
        }
        
        return combinedSentences
    }
    
    /// 줄 단위로 먼저 쪼개고, 긴 줄은 문장 단위로 추가 분할
    public static func splitByLines(_ text: String, maxCharsPerChunk: Int = 40) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        var result: [String] = []
        for line in lines {
            if line.count <= maxCharsPerChunk {
                result.append(line)
            } else {
                // 긴 줄은 문장 단위로 추가 분할
                let sentences = splitIntoSentences(line, minWordsPerSentence: 0)
                result.append(contentsOf: sentences)
            }
        }
        
        return result.isEmpty ? [text] : result
    }
    
    /// 짧은 청크를 병합하여 WebSocket 왕복 횟수 최소화
    public static func mergeShortChunks(
        _ chunks: [String],
        minChars: Int = 20,
        maxChars: Int = 80,
        separator: String = " "
    ) -> [String] {
        guard !chunks.isEmpty else { return chunks }
        
        var result: [String] = []
        var buffer = ""
        
        let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]
        
        for chunk in chunks {
            if buffer.isEmpty {
                buffer = chunk
            } else if (buffer.count + separator.count + chunk.count) <= maxChars {
                // 병합 시 이전 버퍼 끝에 문장부호 없으면 마침표 추가 (TTS 끊어읽기용)
                if let last = buffer.last, !sentenceEndings.contains(last) {
                    buffer += "."
                }
                buffer += separator + chunk
            } else {
                result.append(buffer)
                buffer = chunk
            }
        }
        
        // 마지막 버퍼: 너무 짧으면 이전 청크에 붙임
        if !buffer.isEmpty {
            if buffer.count < minChars, !result.isEmpty {
                result[result.count - 1] += separator + buffer
            } else {
                result.append(buffer)
            }
        }
        
        return result
    }
    
    public static func analyzeText(_ text: String) -> (sentences: [String], wordCounts: [Int]) {
        let sentences = splitIntoSentences(text)
        let wordCounts = sentences.map { sentence in
            sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        }
        return (sentences, wordCounts)
    }
}