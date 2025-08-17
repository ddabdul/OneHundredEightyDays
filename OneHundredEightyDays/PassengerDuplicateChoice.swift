//
//  NameDedupService.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 17/08/2025.
//

import Foundation
import CoreData
import os

// MARK: - Notifications (mirrors Trip duplicate toast pattern)

extension Notification.Name {
    /// Fired to request a user decision when a similar passenger already exists.
    /// UI should listen to this and present an alert/confirmation dialog with 2 actions:
    /// - "Use Existing" → reply with `.passengerDuplicateAnswered` and choice = useExisting
    /// - "Create New"   → reply with `.passengerDuplicateAnswered` and choice = createNew
    static let passengerDuplicatePrompt = Notification.Name("PassengerDuplicatePrompt")

    /// UI replies to the prompt with this notification, echoing back the `promptID`.
    /// userInfo:
    ///   - "promptID": UUID
    ///   - "choice": String ("useExisting" | "createNew")
    static let passengerDuplicateAnswered = Notification.Name("PassengerDuplicateAnswered")
}

// MARK: - Reply choice

private enum PassengerDuplicateChoice: String {
    case useExisting
    case createNew
}

// MARK: - Service

/// A helper that:
/// 1) Normalizes the input full name
/// 2) Uses DuplicateChecker to find a potential match
/// 3) If **100% match**: auto-uses existing (no prompt)
/// 4) If <100% match: prompts user to choose existing vs create new
/// 5) If no match: creates a new temporary entity (unsaved) and returns it
///
/// Designed to be called from the main actor (it posts UI notifications and awaits a reply).
@MainActor
public final class NameDedupService {

    private let context: NSManagedObjectContext
    private let log = Logger(subsystem: "OneHundredEightyDays", category: "NameDedupService")

    /// Treat scores at or above this value as "100%" due to floating-point noise.
    private let exactMatchTolerance = 0.999

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Find or create a passenger-like entity by fuzzy name matching with auto-accept on exact matches.
    ///
    /// - Parameters:
    ///   - entityName: Core Data entity name (e.g., "TripEntity")
    ///   - nameKeyPath: String attribute that stores the full name (e.g., "passenger")
    ///   - inputFullName: Raw name from barcode / manual input
    ///   - threshold: Similarity threshold (0...1) for "possible duplicate"
    ///   - makeNew: Factory to create a *temporary* new entity in `context` with the cleaned name
    ///
    /// - Returns: A `DedupDecision<Entity>` indicating whether we returned an existing match or created new
    public func deduplicateOrCreate<Entity: NSManagedObject>(
        entityName: String,
        nameKeyPath: String,
        inputFullName: String,
        threshold: Double = 0.82,
        makeNew: (NSManagedObjectContext, String) -> Entity
    ) async throws -> DedupDecision<Entity> {

        // 1) Normalize the user input using your String extensions (NameMatching.swift)
        let cleaned = inputFullName.normalizedName

        // 2) Use DuplicateChecker to look for a close match
        let checker = DuplicateChecker<Entity>(
            context: context,
            entityName: entityName,
            nameKeyPath: nameKeyPath
        )

        let candidate = try checker.findPotentialDuplicate(
            for: cleaned,
            threshold: threshold,
            fetchLimit: 2000
        )

        // 3) No likely duplicate → create fresh
        guard let candidate else {
            let fresh = makeNew(context, cleaned)
            log.debug("No passenger duplicate found. Creating new entity.")
            return .createdNew(fresh, score: 0)

        }

        // 4) If the similarity is *effectively 100%*, auto-accept the existing record (NO PROMPT)
        if candidate.bestScore >= exactMatchTolerance {
            let existingName = (candidate.object.value(forKey: nameKeyPath) as? String) ?? "—"
            log.notice("Auto-accepted existing passenger (100% similarity): \(existingName, privacy: .public)")
            return .useExisting(candidate.object, score: candidate.bestScore)

        }

        // 5) Otherwise, prompt the user for a choice (<100% similarity)
        let existingName = (candidate.object.value(forKey: nameKeyPath) as? String) ?? "—"
        let percent = Int(round(candidate.bestScore * 100))
        let promptID = UUID()

        let message = """
        A passenger with a similar name already exists.
        New: \(cleaned)
        Existing: \(existingName)
        Match: \(percent)% similar
        """

        NotificationCenter.default.post(
            name: .passengerDuplicatePrompt,
            object: nil,
            userInfo: [
                "promptID": promptID,
                "message": message,
                "newName": cleaned,
                "existingName": existingName,
                "similarity": candidate.bestScore
            ]
        )

        log.notice("Prompted user for passenger dedup decision (similarity: \(percent)%)")

        let choice = try await awaitUserDecision(promptID: promptID)

        switch choice {
        case .useExisting:
            log.notice("User chose to use existing passenger: \(existingName, privacy: .public)")
            return .useExisting(candidate.object, score: candidate.bestScore)


        case .createNew:
            let fresh = makeNew(context, cleaned)
            log.notice("User chose to create a new passenger: \(cleaned, privacy: .public)")
            return .createdNew(fresh, score: candidate.bestScore)

        }
    }

    // MARK: - Await user reply (async sequence; avoids @Sendable capture issues)

    private func awaitUserDecision(promptID: UUID) async throws -> PassengerDuplicateChoice {
        let center = NotificationCenter.default
        let sequence = center.notifications(named: .passengerDuplicateAnswered, object: nil)

        for await note in sequence {
            guard
                let info = note.userInfo,
                let repliedID = info["promptID"] as? UUID,
                repliedID == promptID,
                let raw = info["choice"] as? String,
                let choice = PassengerDuplicateChoice(rawValue: raw)
            else {
                continue
            }
            return choice
        }

        // If the sequence ends unexpectedly, surface cancellation.
        throw CancellationError()
    }
}
