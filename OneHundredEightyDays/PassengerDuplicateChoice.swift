///
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

/// A small helper that:
/// 1) Normalizes the input full name
/// 2) Uses DuplicateChecker to find a potential match
/// 3) If none: creates a new temporary entity (unsaved) and returns it
/// 4) If found: asks the user (via Notification) whether to use the existing one or create new,
///    then returns the chosen entity.
///
/// Designed to be called from the main actor (it posts UI notifications and awaits a reply).
@MainActor
public final class NameDedupService {

    private let context: NSManagedObjectContext
    private let log = Logger(subsystem: "OneHundredEightyDays", category: "NameDedupService")

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Find or create a passenger-like entity by fuzzy name matching and explicit user confirmation.
    ///
    /// - Parameters:
    ///   - entityName: Core Data entity name (e.g., "PassengerEntity")
    ///   - nameKeyPath: String attribute that stores the full name (e.g., "fullName")
    ///   - inputFullName: Raw name from barcode / manual input
    ///   - threshold: Similarity threshold (0...1).
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

        // 1) Normalize
        let cleaned = inputFullName.normalizedName

        // 2) Duplicate lookup
        let checker = DuplicateChecker<Entity>(context: context,
                                               entityName: entityName,
                                               nameKeyPath: nameKeyPath)

        let candidate = try checker.findPotentialDuplicate(for: cleaned,
                                                           threshold: threshold,
                                                           fetchLimit: 2000)

        // 3) No likely duplicate → create fresh
        guard let candidate else {
            let fresh = makeNew(context, cleaned)
            log.debug("No passenger duplicate found. Creating new entity.")
            return .createdNew(fresh)
        }

        // 4) Likely duplicate → prompt the user
        let existingName = (candidate.object.value(forKey: nameKeyPath) as? String) ?? "—"
        let percent = Int(round(candidate.bestScore * 100))
        let promptID = UUID()

        let message = """
        A passenger with a very similar name already exists.
        New: \(cleaned)
        Existing: \(existingName)
        Match: \(percent)% similar
        """

        NotificationCenter.default.post(name: .passengerDuplicatePrompt,
                                        object: nil,
                                        userInfo: [
                                            "promptID": promptID,
                                            "message": message,
                                            "newName": cleaned,
                                            "existingName": existingName,
                                            "similarity": candidate.bestScore
                                        ])

        log.notice("Prompted user for passenger dedup decision (similarity: \(percent)%)")

        // 5) Await the decision (uses async Notification sequence; no captured mutable state)
        let choice = try await awaitUserDecision(promptID: promptID)

        switch choice {
        case .useExisting:
            log.notice("User chose to use existing passenger: \(existingName, privacy: .public)")
            return .useExisting(candidate.object)

        case .createNew:
            let fresh = makeNew(context, cleaned)
            log.notice("User chose to create a new passenger: \(cleaned, privacy: .public)")
            return .createdNew(fresh)
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
