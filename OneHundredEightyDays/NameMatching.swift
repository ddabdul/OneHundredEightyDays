//
//  NameMatching.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 16/08/2025.
//

import Foundation
import CoreData

// MARK: - Improved normalization for airline-style names
extension String {
    /// Normalize name text for robust comparison:
    /// - Replaces airline separators (/ , ; : + -) with spaces
    /// - Removes diacritics & case
    /// - Collapses whitespace
    /// - Keeps only letters and spaces
    /// - Strips common honorifics appended to first names (e.g., "DELPHINEMRS" -> "DELPHINE")
    var normalizedName: String {
        // 1) Replace common separators with spaces so tokens don't glue together
        let separatorsReplaced = self.replacingOccurrences(of: "[/,;:+-]", with: " ", options: .regularExpression)

        // 2) Fold diacritics & lowercase (will uppercase later)
        let folded = separatorsReplaced.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // 3) Collapse whitespace
        let collapsed = folded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 4) Keep only letters and spaces
        let filteredScalars = collapsed.unicodeScalars.filter { CharacterSet.letters.union(.whitespaces).contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars)).uppercased()

        // 5) Strip honorific suffixes that sometimes get appended to first names in raw boarding-pass text
        //    e.g., "ELAMINE/DELPHINEMRS" -> tokens ["ELAMINE", "DELPHINE"]
        let honorifics = ["MR", "MRS", "MS", "MISS", "DR", "M"] // extend as needed
        let tokens = filtered.split(separator: " ").map { String($0) }
        let cleanedTokens: [String] = tokens.map { token in
            if let h = honorifics.first(where: { token.hasSuffix($0) && token.count > $0.count + 1 }) {
                return String(token.dropLast(h.count))
            }
            return token
        }

        return cleanedTokens.joined(separator: " ")
    }

    /// Split into tokens (words) after normalization.
    var nameTokens: [String] {
        normalizedName.split(separator: " ").map { String($0) }
    }

    /// First letter or empty
    var firstLetter: String {
        return self.isEmpty ? "" : String(self[self.startIndex])
    }
}

// MARK: - Levenshtein + similarity

fileprivate func levenshtein(_ a: String, _ b: String) -> Int {
    if a == b { return 0 }
    let aChars = Array(a)
    let bChars = Array(b)
    let n = aChars.count
    let m = bChars.count
    if n == 0 { return m }
    if m == 0 { return n }

    var dp = Array(0...m)
    for i in 1...n {
        var prev = dp[0]
        dp[0] = i
        for j in 1...m {
            let temp = dp[j]
            let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
            dp[j] = min(
                dp[j] + 1,        // deletion
                dp[j-1] + 1,      // insertion
                prev + cost       // substitution
            )
            prev = temp
        }
    }
    return dp[m]
}

fileprivate func similarity(_ a: String, _ b: String) -> Double {
    if a.isEmpty && b.isEmpty { return 1.0 }
    let maxLen = max(a.count, b.count)
    if maxLen == 0 { return 1.0 }
    let dist = levenshtein(a, b)
    return 1.0 - Double(dist) / Double(maxLen)
}

// MARK: - Variant generation

fileprivate func candidateVariants(for fullName: String) -> [String] {
    let tokens = fullName.nameTokens
    guard !tokens.isEmpty else { return [] }
    let joined = tokens.joined(separator: " ")
    var variants: Set<String> = [joined]

    // LAST FIRST (swap) if at least two tokens
    if tokens.count >= 2 {
        let swapped = ([tokens.last!] + tokens.dropLast()).joined(separator: " ")
        variants.insert(swapped)
    }
    // Remove middle names
    if tokens.count > 2 {
        let firstLast = [tokens.first!, tokens.last!].joined(separator: " ")
        variants.insert(firstLast)
        let lastFirst = [tokens.last!, tokens.first!].joined(separator: " ")
        variants.insert(lastFirst)
    }
    // Initials for middle names (e.g., JOHN A DOE -> JOHN A DOE and JOHN DOE)
    if tokens.count >= 3 {
        var withInitials = tokens
        for i in 1..<(tokens.count - 1) {
            if let firstChar = tokens[i].first {
                withInitials[i] = String(firstChar)
            }
        }
        variants.insert(withInitials.joined(separator: " "))
    }
    return Array(variants)
}

// MARK: - Public matcher

public struct NameMatchResult<T: NSManagedObject> {
    public let object: T
    public let bestScore: Double
    public let comparedAgainst: String
}

public enum DedupDecision<T: NSManagedObject> {
    case useExisting(T)
    case createdNew(T)
}

public enum DedupError: Error {
    case noEntityName
}

public final class NameMatcher {
    /// Compute best similarity between two full names, considering variants
    public static func bestSimilarity(between lhs: String, and rhs: String) -> (score: Double, variant: String) {
        let lhsVariants = candidateVariants(for: lhs)
        let rhsVariants = candidateVariants(for: rhs)
        var best = 0.0
        var bestPair = ""

        for lv in lhsVariants {
            for rv in rhsVariants {
                let s = similarity(lv, rv)
                if s > best {
                    best = s
                    bestPair = rv
                }
            }
        }

        // Fallback: if no variants (e.g., single token)
        if lhsVariants.isEmpty || rhsVariants.isEmpty {
            let s = similarity(lhs.normalizedName, rhs.normalizedName)
            return (s, rhs.normalizedName)
        }
        return (best, bestPair)
    }
}
