import SwiftUI
import ValorantAPI
import UserDefault
import HandyOperators
import WidgetKit

@MainActor
final class AssetManager: ObservableObject {
	@Published private(set) var assets: AssetCollection?
	@Published private(set) var error: Error?
	private var isDownloading = false
	
	var languageOverride: String? {
		storage.languageOverride
	}
	
	@Published private var storage: Storage

	init() {
		// assets used to live in user defaults, which is far too small for them (see Storage.assets)
		UserDefaults.shared.removeObject(forKey: "AssetManager.stored")

		let storage = Storage()
		self.storage = storage
		self.assets = storage.assets

		Task { await tryLoadAssets() }
	}

	private init(assets: AssetCollection?) {
		self.storage = Storage()
		self.assets = assets

		Task { await tryLoadAssets() }
	}
	
	func setLanguageOverride(to language: String?) async {
		storage.languageOverride = language
		await tryLoadAssets()
		WidgetCenter.shared.reloadAllTimelines()
	}
	
	func tryLoadAssets() async {
		guard !isDownloading else { return }
		isDownloading = true
		defer { isDownloading = false }
		
		self.error = nil
		do {
			assets = try await loadAssets()
		} catch {
			self.error = error
		}
	}
	
	func reset() async {
		error = nil
		assets = nil
		storage.assets = nil
	}
	
	#if DEBUG
	static let forPreviews = AssetManager()
	static let mockEmpty = AssetManager(assets: nil)
	#endif
	
	private func loadAssets() async throws -> AssetCollection {
		let language = languageOverride
		?? Bundle.preferredLocalizations(from: Locale.valorantLanguages).first
		?? "en-US"
		let client = AssetClient(language: language)
		
		let version = try await client.getCurrentVersion()
		if let stored = storage.assets, stored.version == version, stored.language == language {
			return stored
		} else {
			return try await client.collectAssets(for: version)
			<- { storage.assets = $0 }
		}
	}
	
	private struct Storage {
		/// This is several megabytes, which is far too much for user defaults: iOS refuses to store over 4 MB in one domain, and the failed write also lost values stored alongside it (like the signed-in accounts). So it's kept in a file instead.
		var assets: AssetCollection? = Self.loadAssets() {
			didSet { Self.save(assets) }
		}
		@UserDefault("AssetManager.languageOverride", defaults: .shared)
		var languageOverride: String?

		private static func loadAssets() -> AssetCollection? {
			guard let url = FolderLocations.storedAssets, let data = try? Data(contentsOf: url) else { return nil }
			do {
				return try JSONDecoder().decode(AssetCollection.self, from: data)
			} catch {
				print("could not decode stored assets:", error)
				return nil
			}
		}

		private static func save(_ assets: AssetCollection?) {
			guard let url = FolderLocations.storedAssets else { return }
			do {
				if let assets {
					try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
					try JSONEncoder().encode(assets).write(to: url, options: .atomic)
				} else if FileManager.default.fileExists(atPath: url.path) {
					try FileManager.default.removeItem(at: url)
				}
			} catch {
				print("could not store assets:", error)
			}
		}
	}
}

extension EnvironmentValues {
	var assets: AssetCollection? {
		get { self[Key.self] }
		set { self[Key.self] = newValue }
	}
	
	private enum Key: EnvironmentKey {
		#if WIDGETS
		@MainActor static let defaultValue: AssetCollection? = Managers.assets.assets
		#elseif DEBUG
		@MainActor static let defaultValue = isInSwiftUIPreview ? AssetManager.forPreviews.assets : nil
		#else
		@MainActor static let defaultValue: AssetCollection? = nil
		#endif
	}
}
