import SwiftUI
import ValorantAPI

struct ScoreboardView: View {
	let data: MatchViewData
	@Binding var highlight: PlayerHighlightInfo
	
	@State private var width = 0.0
	@Environment(\.valorantLoad) private var load
	
	var body: some View {
		VStack {
			let sorted = data.details.players.sorted { $0.score > $1.score }
			
			ScrollView(.horizontal, showsIndicators: false) {
				VStack(spacing: ScoreboardRowView.padding) {
					ForEach(sorted) { player in
						ScoreboardRowView(player: player, data: data, highlight: $highlight)
					}
				}
				.padding(.horizontal)
				.frame(minWidth: width)
			}
			.measured { width = $0.width }
			
			AsyncButton(action: fetchRanks) {
				Text("Update Ranks", comment: "Match Details: button")
			}
			.buttonStyle(.bordered)
		}
		.task {
			// match details no longer include names, so look them all up in one go
			await load {
				try await $0.fetchUsers(for: Array(data.players.keys))
			}
		}
	}
	
	private func fetchRanks() async {
		await load {
			for playerID in data.players.keys {
				try await $0.fetchCareerSummary(for: playerID)
			}
		}
	}
}

struct ScoreboardRowView: View {
	static let padding = 6.0
	private static let height = 44.0
	private static let rankSize = height - 2 * padding
	/// distinct from the team colors, so parties stand out
	private static let partyColors: [Color] = [.orange, .purple, .yellow, .green, .brown]

	let player: Player
	let data: MatchViewData
	@Binding var highlight: PlayerHighlightInfo

	@LocalData var summary: CareerSummary?
	@LocalData var user: User?
	
	@Environment(\.shouldAnonymize) private var shouldAnonymize
	
	var body: some View {
		let divider = Rectangle()
			.frame(width: 1)
			.blendMode(.destinationOut)
		let relativeColor = data.relativeColor(of: player)
		
		HStack(spacing: Self.padding) {
			// marks players queued up together
			(partyColor ?? .clear)
				.frame(width: Self.padding)
				.opacity(highlight.shouldFade(player.partyID) ? 0.5 : 1)

			ZStack {
				if let agentID = player.agentID {
					AgentImage.icon(agentID)
						.dynamicallyStroked(radius: 1, color: .white)
				} else {
					Image(systemName: "eye")
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.aspectRatio(1, contentMode: .fit)
			.background(relativeColor.opacity(0.5))
			.compositingGroup()
			.opacity(highlight.shouldFade(player.id) ? 0.5 : 1)
			
			HStack {
				identitySection
					.foregroundColor(relativeColor)
				
				divider
				
				ZStack {
					if let score = player.stats?.score {
						let roundsPlayed = data.details.roundResults.count
						Text(verbatim: "\(score / roundsPlayed)")
					} else {
						Text("–").foregroundStyle(.secondary)
					}
				}
				.frame(width: 60)
				
				divider
				
				KDASummaryView(player: player)
					.frame(width: 120)
			}
			.padding(.vertical, Self.padding)

			relativeColor
				.frame(width: Self.padding)
		}
		.background(relativeColor.opacity(0.25))
		.frame(height: Self.height)
		.cornerRadius(Self.padding)
		.compositingGroup() // for the destination-out blending
		.onTapGesture {
			highlight.switchHighlight(to: player)
		}
		.withLocalData($summary, id: player.id)
		.withLocalData($user, id: player.id, shouldAutoUpdate: false) // fetched for everyone at once by the scoreboard
	}

	private var partyColor: Color? {
		data.parties.firstIndex(of: player.partyID)
			.map { Self.partyColors[$0 % Self.partyColors.count] }
	}

	@ViewBuilder
	var identitySection: some View {
		let name = player.gameName.isEmpty ? user?.gameName : player.gameName
		Group {
			if !shouldAnonymize(player.id), let name, !name.isEmpty {
				Text(name)
			} else {
				Text("Player")
					.foregroundStyle(.secondary)
			}
		}
		.font(.body.weight(
			highlight.isHighlighting(player.partyID)
				.map { $0 ? .semibold : .regular }
			?? .medium
		))
		.fixedSize()
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.trailing, 4)
		
		Spacer()
		
		if player.id != data.myself?.id {
			TransparentNavigationLink {
				MatchListView(userID: player.id)
			} label: {
				Image(systemName: "person.crop.circle.fill")
					.frame(maxHeight: .infinity)
					.padding(.horizontal, 4)
			}
		}
		
		rankIcon
			.frame(width: Self.rankSize, height: Self.rankSize)
	}

	/// the rank they had in this match, falling back on their current one (from "Update Ranks") if the match doesn't say
	@ViewBuilder
	var rankIcon: some View {
		if player.competitiveTier > 0 {
			CompetitiveTierImage(tier: player.competitiveTier, actID: data.details.matchInfo.seasonID)
		} else {
			RankInfoView(
				summary: summary,
				size: Self.rankSize,
				lineWidth: 2,
				shouldShowProgress: false,
				shouldFadeUnranked: true
			)
			.foregroundColor(nil)
		}
	}
}

extension ScoreboardRowView {
	init(player: Player, data: MatchViewData, highlight: Binding<PlayerHighlightInfo>) {
		self.init(
			player: player, data: data, highlight: highlight,
			summary: .init(id: player.id),
			user: .init(id: player.id)
		)
	}
}

#if DEBUG
struct ScoreboardView_Previews: PreviewProvider {
	static var previews: some View {
		Group {
			ScoreboardView(data: PreviewData.singleMatchData, highlight: .constant(.init()))
				.padding(.vertical)
			
			ScoreboardRowView(
				player: PreviewData.singleMatch.players[0],
				data: PreviewData.singleMatchData,
				highlight: .constant(.init())
			)
			.padding()
		}
		.fixedSize(horizontal: true, vertical: true)
		.previewLayout(.sizeThatFits)
	}
}
#endif
