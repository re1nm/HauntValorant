import Foundation
import ErgonomicCodable

public struct ContractDetails: Equatable, Codable {
	public var missions: [Mission]
	public var missionMetadata: MissionMetadata
	// Technically this object also lists contract progress and processed matches, but nothing uses those. Contracts in particular are gone from the game, and their progress no longer matches the format this used to decode.

	private enum CodingKeys: String, CodingKey {
		case missions = "Missions"
		case missionMetadata = "MissionMetadata"
	}
	
	public struct MissionMetadata: Equatable, Codable {
		/// `nil` when not completed
		public var hasCompletedNewPlayerExperience: Bool?
		/// The activation date for the last set of weeklies the user has completed.
		/// - Note: Can be `nil` for users that haven't completed any weeklies this act.
		public var weeklyCheckpoint: Date?
		/// When the next set of weekly missions will become available.
		public var weeklyRefillTime: Date?
		
		private enum CodingKeys: String, CodingKey {
			case hasCompletedNewPlayerExperience = "NPECompleted"
			case weeklyCheckpoint = "WeeklyCheckpoint"
			case weeklyRefillTime = "WeeklyRefillTime"
		}
	}
}

/// Only contract IDs are still around, e.g. in inventories and the accessory store.
public enum Contract {
	public typealias ID = ObjectID<Self, LowercaseUUID>
}

public struct Mission: Equatable, Codable, Identifiable {
	public typealias ID = ObjectID<Self, LowercaseUUID>
	public var id: ID
	
	@StringKeyedDictionary
	public var objectiveProgress: [Objective.ID: Int]
	public var isComplete: Bool
	public var expirationTime: Date?
	
	private enum CodingKeys: String, CodingKey {
		case id = "ID"
		case objectiveProgress = "Objectives"
		case isComplete = "Complete"
		case expirationTime = "ExpirationTime"
	}
}

public enum Objective {
	public typealias ID = ObjectID<Self, LowercaseUUID>
}

public struct DailyTicketProgress: Codable {
	public static let zero = Self(
		remainingTime: 0,
		milestones: .init(repeating: .zero, count: 4)
	)
	
	public var remainingTime: TimeInterval
	public var milestones: [Milestone]
	
	private enum CodingKeys: String, CodingKey {
		case remainingTime = "RemainingLifetimeSeconds"
		case milestones = "Milestones"
	}
	
	public struct Milestone: Codable {
		public static let zero = Self(progress: 0, wasRedeemed: false)
		
		/// 0-4
		public var progress: Int
		/// honestly i can't figure out the logic behind when this is set to true vs left as false
		public var wasRedeemed: Bool
		public var isComplete: Bool { progress >= 4 }
		
		private enum CodingKeys: String, CodingKey {
			case progress = "Progress"
			case wasRedeemed = "BonusApplied"
		}
	}
}
