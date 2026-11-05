// https://stackoverflow.com/a/67853022/3213030
#if canImport(SwiftUI) && !arch(arm) // swiftui is weird about 32-bit arm; need this for release builds
import SwiftUI

// TODO: could probably use environment to accept defaults suite; would have to use update() method to apply it i think

extension UserDefault {
	/// lightweight wrapper to ease the composition of `@State` with `@UserDefault`
	@available(iOS 13, macOS 10.15, tvOS 13, watchOS 6, *)
	@propertyWrapper
	public struct State: DynamicProperty {
		// stacking @UserDefault under @State no longer compiles now that @State is a macro (Xcode 27), so hold the composition explicitly
		@SwiftUI.State private var inner: UserDefault<Value>

		public var wrappedValue: Value {
			get { inner.wrappedValue }
			nonmutating set { inner.wrappedValue = newValue }
		}

		public var projectedValue: Binding<Value> {
			$inner[dynamicMember: \.wrappedValue]
		}

		private init(inner: UserDefault<Value>) {
			_inner = .init(wrappedValue: inner)
		}
		
		public init(wrappedValue: Value, _ key: String) {
			self.init(inner: UserDefault(wrappedValue: wrappedValue, key))
		}
		
		public init(_ key: String) where Value: ExpressibleByNilLiteral {
			self.init(wrappedValue: nil, key)
		}
	}
}
#endif
