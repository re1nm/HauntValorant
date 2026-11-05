import Foundation
import Protoquest

extension ValorantClient {
	public func getLoadout() async throws -> Loadout {
		try await send(LoadoutRequest(playerID: userID))
	}
	
	public func updateLoadout(to loadout: Loadout) async throws -> Loadout {
		try await send(LoadoutUpdateRequest(playerID: userID, loadout: loadout))
	}
	
	struct LoadoutRequest: GetJSONRequest, GameDataRequest {
		var playerID: Player.ID
		
		var path: String {
			"/personalization/v3/players/\(playerID)/playerloadout"
		}

		typealias Response = Loadout

		func decodeResponse(from raw: Protoresponse) throws -> Loadout {
			do {
				return try raw.decodeJSON()
			} catch {
				if
					let string = try? raw.decodeString(using: .utf8),
					string.contains("00000000-0000-0000-0000-000000000000")
				{
					throw Loadout.FetchError.uninitialized(playerID)
				}
				throw error
			}
		}
	}
	
	struct LoadoutUpdateRequest: JSONJSONRequest, GameDataRequest {
		var playerID: Player.ID
		var loadout: Loadout
		
		var body: Loadout { loadout }
		var httpMethod: String { "PUT" }

		var path: String {
			"/personalization/v3/players/\(playerID)/playerloadout"
		}
		
		typealias Response = Loadout
	}
}

extension Loadout {
	public enum FetchError: Error, LocalizedError {
		/// Thrown for loadouts initialized to the default zeroed-out UUIDs and missing properties.
		/// If you get this, you've likely signed into the wrong account (or somehow fetched data for the wrong region).
		case uninitialized(Player.ID)
		
		public var errorDescription: String? {
			switch self {
			case .uninitialized:
				return "It looks like this account has never played Valorant in this region!"
			}
		}
	}
}

public struct Loadout: Codable {
	public var subject: User.ID
	/// incremented every time the loadout is changed
	public var version: Int
	public var isIncognito: Bool
	public var identity: Identity
	public var guns: [Gun]
	/// What's on the expression wheel (sprays and flex items), in ``Spray/Slot/ID/inWheelOrder``.
	public var expressions: [Expression]
	/// Nothing uses this (it's been empty so far), but it's sent back as-is when updating.
	var dynamicOptions: [String: JSONValue]

	private enum CodingKeys: String, CodingKey {
		case subject = "Subject"
		case version = "Version"
		case identity = "Identity"
		case guns = "Guns"
		case expressions = "ActiveExpressions"
		case dynamicOptions = "DynamicOptions"
		case isIncognito = "Incognito"
	}

	public struct Gun: Codable {
		public var id: Weapon.ID
		public var skin: Skin
		public var buddy: Buddy?
		/// Nothing uses these (they've been empty so far), but they're sent back as-is when updating.
		var attachments: [JSONValue]

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try container.decodeValue(forKey: .id)
			attachments = try container.decodeIfPresent([JSONValue].self, forKey: .attachments) ?? []

			let nested = try decoder.singleValueContainer()
			skin = try nested.decode(Skin.self)
			buddy = container.allKeys.contains(.buddyID) ? try nested.decode(Buddy.self) : nil
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(id, forKey: .id)
			try container.encode(attachments, forKey: .attachments)

			try skin.encode(to: encoder)
			try buddy?.encode(to: encoder)
		}

		private enum CodingKeys: String, CodingKey {
			case id = "ID"
			case buddyID = "CharmID"
			case attachments = "Attachments"
		}
		
		public struct Skin: Codable {
			public var skin: Weapon.Skin.ID
			public var level: Weapon.Skin.Level.ID
			/// can be nil for freshly-bought lvl1 skins!
			public var chroma: Weapon.Skin.Chroma.ID?
			
			public init(
				skin: Weapon.Skin.ID,
				level: Weapon.Skin.Level.ID,
				chroma: Weapon.Skin.Chroma.ID?
			) {
				self.skin = skin
				self.level = level
				self.chroma = chroma
			}
			
			private enum CodingKeys: String, CodingKey {
				case skin = "SkinID"
				case level = "SkinLevelID"
				case chroma = "ChromaID"
			}
		}
		
		public struct Buddy: Equatable, Codable {
			public var buddy: Weapon.Buddy.ID
			public var level: Weapon.Buddy.Level.ID
			public var instance: Weapon.Buddy.Instance.ID
			
			public init(
				buddy: Weapon.Buddy.ID,
				level: Weapon.Buddy.Level.ID,
				instance: Weapon.Buddy.Instance.ID
			) {
				self.buddy = buddy
				self.level = level
				self.instance = instance
			}
			
			private enum CodingKeys: String, CodingKey {
				case buddy = "CharmID"
				case level = "CharmLevelID"
				case instance = "CharmInstanceID"
			}
		}
	}
	
	public struct Expression: Equatable, Codable {
		/// What kind of item this is: ``ItemType/ID/sprays`` or e.g. a flex item.
		public var type: ItemType.ID
		public var asset: LowercaseUUID

		public init(spray: Spray.ID) {
			type = .sprays
			asset = spray.rawID
		}

		/// The spray this is, if it's not something else like a flex item.
		public var spray: Spray.ID? {
			type == .sprays ? .init(rawID: asset) : nil
		}

		private enum CodingKeys: String, CodingKey {
			case type = "TypeID"
			case asset = "AssetID"
		}
	}
	
	public struct Identity: Codable {
		public var card: PlayerCard.ID
		public var title: PlayerTitle.ID
		public var levelBorder: LevelBorder.ID
		public var isLevelHidden: Bool
		
		private enum CodingKeys: String, CodingKey {
			case card = "PlayerCardID"
			case title = "PlayerTitleID"
			case levelBorder = "PreferredLevelBorderID"
			case isLevelHidden = "HideAccountLevel"
		}
	}
}

extension LowercaseUUID {
	// i DESPISE when people (riot…) do this. null exists for a reason!!!!
	private static let stupidNullID = Self(.init(uuidString: "00000000-0000-0000-0000-000000000000")!)
	
	public var isPseudoNull: Bool {
		self == .stupidNullID
	}
}

extension ObjectID where RawID == LowercaseUUID {
	/// player cards/titles/level borders are initially set to an all-zeroes ID rather than null for no good reason.
	public var isPseudoNull: Bool {
		rawID.isPseudoNull
	}
}

public struct UpdatableLoadout {
	public let subject: User.ID
	public var isIncognito: Bool
	public var identity: Loadout.Identity
	public var guns: [Weapon.ID: Loadout.Gun]
	public var sprays: [Spray.Slot.ID: Spray.ID]
	/// the wheel as fetched, so expressions other than sprays (like flex items) stay in place when updating
	fileprivate let fetchedExpressions: [Spray.Slot.ID: Loadout.Expression]
	fileprivate let dynamicOptions: [String: JSONValue]

	public init(_ loadout: Loadout) {
		subject = loadout.subject
		isIncognito = loadout.isIncognito
		identity = loadout.identity
		guns = .init(uniqueKeysWithValues: loadout.guns.map { ($0.id, $0) })
		fetchedExpressions = .init(uniqueKeysWithValues: zip(Spray.Slot.ID.inWheelOrder, loadout.expressions))
		sprays = fetchedExpressions.compactMapValues(\.spray)
		dynamicOptions = loadout.dynamicOptions
	}

	public func currentWeapon(for instance: Weapon.Buddy.Instance.ID) -> Weapon.ID? {
		guns.values.first { $0.buddy?.instance == instance }?.id
	}

	/// Whether this slot holds something other than a spray, like a flex item.
	public func hasOtherExpression(in slot: Spray.Slot.ID) -> Bool {
		sprays[slot] == nil && fetchedExpressions[slot] != nil
	}
}

extension Loadout {
	public init(_ loadout: UpdatableLoadout) {
		subject = loadout.subject
		version = -1
		isIncognito = loadout.isIncognito
		identity = loadout.identity
		guns = .init(loadout.guns.values)
		expressions = Spray.Slot.ID.inWheelOrder.compactMap { slot in
			loadout.sprays[slot].map(Expression.init(spray:))
			// keep whatever else was there (e.g. a flex item) unless it was replaced or removed
			?? loadout.fetchedExpressions[slot].flatMap { $0.spray == nil ? $0 : nil }
		}
		dynamicOptions = loadout.dynamicOptions
	}
}

/// Arbitrary JSON, for passing along parts of responses that nothing uses but that need to survive a round trip.
enum JSONValue: Hashable, Codable {
	case null
	case bool(Bool)
	case int(Int)
	case double(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Int.self) {
			self = .int(value)
		} else if let value = try? container.decode(Double.self) {
			self = .double(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else {
			self = .object(try container.decode([String: JSONValue].self))
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null:
			try container.encodeNil()
		case .bool(let value):
			try container.encode(value)
		case .int(let value):
			try container.encode(value)
		case .double(let value):
			try container.encode(value)
		case .string(let value):
			try container.encode(value)
		case .array(let value):
			try container.encode(value)
		case .object(let value):
			try container.encode(value)
		}
	}
}
