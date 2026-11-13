import Foundation
import Protoquest

extension ValorantClient {
	/// Looks up a player by their Riot ID, like `Name #Tag` (ignoring case). Returns `nil` if there's no such player.
	///
	/// This goes through Riot's account service, which knows every Riot account, regardless of the region they play in—use ``findLocation(of:)`` to find that out.
	public func lookUpPlayer(gameName: String, tagLine: String) async throws -> User? {
		let matches: [RiotIDLookupRequest.Match]
		do {
			matches = try await send(RiotIDLookupRequest(gameName: gameName, tagLine: tagLine))
		} catch APIError.resourceNotFound {
			return nil
		}
		// Riot IDs are unique, so there's at most one; it comes with the proper capitalization
		return matches.first.map {
			User(id: $0.puuid, gameName: $0.alias.gameName, tagLine: $0.alias.tagLine)
		}
	}

	/// Works out which shard a player plays on, which is where their match history lives.
	///
	/// Each shard only knows about its own players' match histories (and responds with a 404 for others), so this simply checks them in turn, starting with this client's own.
	/// Returns `nil` if none of them know the player, e.g. because they've never played.
	public func findLocation(of userID: User.ID) async throws -> Location? {
		// most of the time, people look up players from their own region
		if try await hasHistory(of: userID, in: location) {
			return location
		}

		let otherShards = [Location.northAmerica, .europe, .asiaPacific, .korea]
			.filter { $0.shard != location.shard }
		return await withTaskGroup(of: Location?.self) { group in
			for other in otherShards {
				group.addTask {
					// a shard we can't reach just doesn't count
					(try? await self.hasHistory(of: userID, in: other)) == true ? other : nil
				}
			}
			for await case let found? in group {
				group.cancelAll()
				return found
			}
			return nil
		}
	}

	private func hasHistory(of userID: User.ID, in location: Location) async throws -> Bool {
		do {
			_ = try await self.in(location).send(MatchHistoryExistenceRequest(userID: userID))
			return true
		} catch APIError.resourceNotFound {
			return false
		}
	}
}

/// Only used to check whether a shard knows a player: the others respond with a 404.
/// (Competitive updates won't do for this, since those come back empty instead.)
private struct MatchHistoryExistenceRequest: GetJSONRequest, GameDataRequest {
	var userID: User.ID

	var path: String {
		"/match-history/v1/history/\(userID)"
	}

	var urlParams: [URLParameter] {
		("startIndex", 0)
		("endIndex", 1)
	}

	/// what's in it doesn't matter, just that there is one
	struct Response: Decodable {}
}

private struct RiotIDLookupRequest: GetJSONRequest, ValorantRequest {
	var gameName: String
	var tagLine: String

	func baseURL(for location: Location) -> URL {
		BaseURLs.accountAPI
	}

	var path: String { "aliases/v1/aliases" }

	var urlParams: [URLParameter] {
		("gameName", gameName)
		("tagLine", tagLine)
	}

	typealias Response = [Match]

	struct Match: Decodable {
		var puuid: User.ID
		var alias: Alias

		struct Alias: Decodable {
			var gameName: String
			var tagLine: String

			private enum CodingKeys: String, CodingKey {
				case gameName = "game_name"
				case tagLine = "tag_line"
			}
		}
	}
}
