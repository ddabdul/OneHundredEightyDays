//
//  TripEntity+CoreDataProperties.swift
//  OneHundredEightyDays
//
//  Created by Olivier on 03/08/2025.
//
//

import Foundation
import CoreData


extension TripEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<TripEntity> {
        return NSFetchRequest<TripEntity>(entityName: "TripEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var departureCity: String?
    @NSManaged public var departureCountry: String?
    @NSManaged public var arrivalCountry: String?
    @NSManaged public var passenger: String?
    @NSManaged public var naturalKey: String?
    @NSManaged public var arrivalCity: String?
    @NSManaged public var travelDate: Date?
    @NSManaged public var airline: String?
    @NSManaged public var flightNumber: String?
    @NSManaged public var departureAirportCode: String?
    @NSManaged public var arrivalAirportCode: String?
    @NSManaged public var imageData: Data?

}

extension TripEntity : Identifiable {

}
