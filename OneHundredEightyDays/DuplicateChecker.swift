//
//  DuplicateChecker.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 16/08/2025.
//


import Foundation
import CoreData

/// Generic Core Data duplicate candidate finder.
/// Assumes your entity has a string attribute for the full name (e.g., "fullName").
public final class DuplicateChecker<Entity: NSManagedObject> {
    private let context: NSManagedObjectContext
    private let entityName: String
    private let nameKeyPath: String

    /// - Parameters:
    ///   - entityName: e.g. "Person"
    ///   - nameKeyPath: e.g. "fullName"
    public init(context: NSManagedObjectContext, entityName: String, nameKeyPath: String = "fullName") {
        self.context = context
        self.entityName = entityName
        self.nameKeyPath = nameKeyPath
    }

    /// Finds the best fuzzy match above `threshold` and returns it (or nil).
    /// - Optimization: prefilters by first letter of last token to avoid scanning everything.
    public func findPotentialDuplicate(for inputFullName: String,
                                       threshold: Double = 0.82,
                                       fetchLimit: Int = 2000) throws -> NameMatchResult<Entity>? {
        let tokens = inputFullName.nameTokens
        let lastTokenFirstLetter = tokens.last?.firstLetter ?? ""

        let request = NSFetchRequest<Entity>(entityName: entityName)
        request.fetchLimit = fetchLimit

        // Coarse prefilter to reduce scanned rows; tune for your schema.
        if !lastTokenFirstLetter.isEmpty {
            // Matches beginning or containing the first letter (case/diacritic-insensitive)
            request.predicate = NSPredicate(format: "%K BEGINSWITH[cd] %@ OR %K CONTAINS[cd] %@",
                                            nameKeyPath, lastTokenFirstLetter,
                                            nameKeyPath, lastTokenFirstLetter)
        }

        let results = try context.fetch(request)

        var best: (obj: Entity, score: Double, against: String)? = nil

        for obj in results {
            guard let value = obj.value(forKey: nameKeyPath) as? String, !value.isEmpty else { continue }
            let (score, against) = NameMatcher.bestSimilarity(between: inputFullName, and: value)
            if best == nil || score > best!.score {
                best = (obj, score, against)
            }
        }

        if let best, best.score >= threshold {
            return NameMatchResult(object: best.obj, bestScore: best.score, comparedAgainst: best.against)
        } else {
            return nil
        }
    }
}
