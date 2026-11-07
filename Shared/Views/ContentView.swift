import SwiftUI
import UIKit
import HandyOperators
import ValorantAPI
import WidgetKit

struct ContentView: View {
	@ObservedObject var accountManager: AccountManager
	@ObservedObject var assetManager: AssetManager
	@ObservedObject var settings: AppSettings
	@ObservedObject var store: InAppStore

	@SceneStorage("tab")
	var tab = Tab.career
	/// slides between tabs when swiping sideways
	@State var tabSwiper = TabSwiper()

	@State var handleDeepLink: DeepLink.Handler?

	var body: some View {
		TabView(selection: $tab) {
			tabContent(.career) {
				onlineView { BookmarkListView(userID: $0) }
			}

			tabContent(.live) {
				onlineView { LiveView(userID: $0) }
			}

			tabContent(.reference) {
				ReferenceView()
			}

			tabContent(.settings) {
				SettingsView(accountManager: accountManager, assetManager: assetManager, settings: settings, store: store)
			}
		}
		.environment(\.tabSwiper, tabSwiper)
		.onAppear { tabSwiper.selection = $tab }
		.task(id: accountManager.requiresAction) {
			if accountManager.requiresAction {
				tab = .settings
			}
		}
		.withValorantLoadFunction(manager: accountManager)
		.withLoadErrorAlerts()
		.onSceneActivation {
			Task { await assetManager.tryLoadAssets() }
		}
		.readingDeepLinkHandler { handleDeepLink = $0 }
		.environment(\.deepLink, handle(_:))
		.onOpenURL(perform: handle(_:))
	}

	private func tabContent<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
		content()
			.swipingBetweenTabs() // from each tab's main screen
			.withToolbar()
			.tabItem { Label(tab.title, systemImage: tab.symbolName) }
			.tag(tab)
	}

	@ViewBuilder
	private func onlineView<Content: View>(
		@ViewBuilder content: @escaping (User.ID) -> Content
	) -> some View {
		UnwrappingView(
			value: accountManager.activeAccount,
			placeholder: "Not signed in!"
		) { account in
			content(account.id)
		}
	}

	func handle(_ url: URL) {
		print("handling", url)
		do {
			if let widgetLink = try WidgetLink(from: url) {
				handle(widgetLink)
			}
		} catch {
			print("could not decode opened url: \(url)")
		}
	}

	func handle(_ link: WidgetLink) {
		guard #available(iOS 16.0, *) else { return }
		print("handling", link)

		if let kind = link.timelinesToReload {
			WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
		}

		if let user = link.account {
			do {
				try accountManager.setActive(user)
			} catch {
				print("error setting account to \(user) for widget link")
			}
		}

		switch link.destination {
		case .career:
			tab = .career
		case .store, .missions:
			tab = .live
		case nil:
			break
		}

		handleWithDelay(.widget(link))
	}

	func handle(_ link: InAppLink) {
		switch link {
		case .storefront:
			tab = .settings
		}

		handleWithDelay(.inApp(link))
	}

	private func handleWithDelay(_ link: DeepLink) {
		// delay to give newly-displayed tabs time to propagate their preferences
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
			handleDeepLink?(link)
		}
	}

	/// in the same order as the tab bar
	enum Tab: String, CaseIterable {
		case career
		case live
		case reference
		case settings

		var index: Int {
			Self.allCases.firstIndex(of: self)!
		}

		var title: String {
			switch self {
			case .career:
				return String(localized: "Career", comment: "Top-Level Tab Title")
			case .live:
				return String(localized: "Live", comment: "Top-Level Tab Title")
			case .reference:
				return String(localized: "Reference", comment: "Top-Level Tab Title")
			case .settings:
				return String(localized: "Settings", comment: "Top-Level Tab Title")
			}
		}

		var symbolName: String {
			switch self {
			case .career:
				return "clock"
			case .live:
				return "play"
			case .reference:
				return "book"
			case .settings:
				return "gearshape"
			}
		}
	}
}

// MARK: - Swiping Between Tabs

extension View {
	/// Lets you swipe sideways on this screen to get to the neighboring tabs, like you can on each tab's main screen.
	///
	/// Screens beyond a tab's main one only swipe on to the next tab, since swiping the other way means going back there.
	func swipingBetweenTabs(isEnabled: Bool = true) -> some View {
		modifier(TabSwipeAreaModifier(isEnabled: isEnabled))
	}
}

private struct TabSwipeAreaModifier: ViewModifier {
	var isEnabled: Bool

	@Environment(\.tabSwiper) private var swiper

	func body(content: Content) -> some View {
		content.background {
			if isEnabled, let swiper {
				TabSwipeArea(swiper: swiper)
			}
		}
	}
}

/// Marks the screen it's in as one you can swipe between tabs from.
private struct TabSwipeArea: UIViewRepresentable {
	var swiper: TabSwiper

	func makeUIView(context: Context) -> MarkerView {
		MarkerView() <- { $0.swiper = swiper }
	}

	func updateUIView(_ view: MarkerView, context: Context) {
		view.swiper = swiper
	}

	final class MarkerView: UIView {
		weak var swiper: TabSwiper?

		override init(frame: CGRect) {
			super.init(frame: frame)
			isUserInteractionEnabled = false
		}

		required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		override func didMoveToWindow() {
			super.didMoveToWindow()
			guard window != nil else { return }
			swiper?.register(self)
		}
	}
}

private struct TabSwiperKey: EnvironmentKey {
	static let defaultValue: TabSwiper? = nil
}

extension EnvironmentValues {
	var tabSwiper: TabSwiper? {
		get { self[TabSwiperKey.self] }
		set { self[TabSwiperKey.self] = newValue }
	}
}

/// Slides between tabs as you swipe sideways, with the old tab following your finger out and the new one coming in alongside it.
///
/// This hooks into the tab bar controller behind SwiftUI's `TabView`, so the system tab bar stays as it is and UIKit does all the moving—
/// nothing in SwiftUI needs to update while the tabs slide, which keeps it smooth.
/// A new swipe can start right away, even while the last one is still settling: it simply picks up from wherever things are on screen.
final class TabSwiper: NSObject {
	/// the tab view's selection, which is kept in line with the tab bar controller
	var selection: Binding<ContentView.Tab>?

	/// the slide that's about to start, for the tab bar controller to ask for
	fileprivate private(set) var startingTransition: TabSlideTransition?
	/// the slide that's following the finger or still settling
	private var transition: TabSlideTransition?

	private weak var tabBarController: UITabBarController?
	private let delegateProxy = TabBarDelegateProxy()
	private lazy var panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))) <- {
		$0.maximumNumberOfTouches = 1
		$0.delegate = self
	}
	/// asks for the highest frame rate (e.g. 120 Hz on ProMotion displays) while following the finger
	private var displayLink: CADisplayLink?
	/// screens (or rather views in them) that allow swiping between tabs
	private let swipeAreas = NSHashTable<UIView>.weakObjects()
	/// what the current touch started on
	private weak var touchedView: UIView?
	/// decided as the swipe begins
	private var plannedSwitch: (target: ContentView.Tab, edge: CGFloat)?

	override init() {
		super.init()
		delegateProxy.swiper = self
	}

	fileprivate func register(_ area: UIView) {
		swipeAreas.add(area)

		// the tab view's tab bar controller is somewhere up the chain
		let controller = sequence(first: area as UIResponder, next: \.next)
			.lazy
			.compactMap { $0 as? UITabBarController }
			.first
		if let controller {
			attach(to: controller)
		}
	}

	private func attach(to controller: UITabBarController) {
		// we only need a say in the transitions; SwiftUI's own delegate takes care of everything else as usual
		if controller.delegate !== delegateProxy {
			delegateProxy.forwardee = controller.delegate
			controller.delegate = delegateProxy
		}

		if panRecognizer.view !== controller.view {
			panRecognizer.view?.removeGestureRecognizer(panRecognizer)
			controller.view.addGestureRecognizer(panRecognizer)
		}

		tabBarController = controller
	}

	@objc private func handlePan(_ pan: UIPanGestureRecognizer) {
		guard let view = pan.view else { return }

		switch pan.state {
		case .began:
			// follow the finger from here on, rather than jumping ahead by however far it had to move to count as a swipe
			pan.setTranslation(.zero, in: view)
			beginSwitch()
		case .changed:
			transition?.update(translation: pan.translation(in: view).x)
		case .ended:
			stopDisplayLink()
			guard let transition else { return }
			transition.update(translation: pan.translation(in: view).x)
			let velocity = pan.velocity(in: view).x
			let speed = -transition.edge * velocity // toward switching
			// a decent flick decides it either way; otherwise it's about whether it's past the halfway point
			let shouldSwitch = abs(speed) > 300 ? speed > 0 : transition.progress > 0.5
			transition.finish(switching: shouldSwitch, velocity: velocity)
		case .cancelled, .failed:
			stopDisplayLink()
			transition?.finish(switching: false, velocity: 0)
		default:
			break
		}
	}

	private func beginSwitch() {
		guard let plannedSwitch, let controller = tabBarController, let selection else { return }
		self.plannedSwitch = nil
		attach(to: controller) // in case SwiftUI swapped out the delegate

		// if the last swipe is still settling, take over from wherever it is on screen right now
		let handover = transition?.interrupt()

		let transition = TabSlideTransition(
			from: selection.wrappedValue,
			to: plannedSwitch.target,
			edge: plannedSwitch.edge,
			handover: handover
		)
		transition.completion = { [weak self, weak transition] didSwitch in
			guard let self, let transition else { return }
			self.slideEnded(transition, didSwitch: didSwitch)
		}
		self.transition = transition

		// switching tabs here (rather than through SwiftUI) starts the slide right away, as the tab bar controller asks us how to transition
		startingTransition = transition
		select(plannedSwitch.target, in: controller)
		startingTransition = nil

		guard transition.isAccepted else {
			// the tab bar controller switched without our slide (which it shouldn't), so there's nothing to follow the finger with
			transition.abandon()
			self.transition = nil
			selection.wrappedValue = selectedTab(in: controller) ?? selection.wrappedValue
			return
		}

		selection.wrappedValue = plannedSwitch.target // keep SwiftUI in line
		startDisplayLink()
	}

	private func slideEnded(_ transition: TabSlideTransition, didSwitch: Bool) {
		if self.transition === transition {
			self.transition = nil
		}

		guard !didSwitch, let tabBarController else { return }
		// the old tab is showing again, but the tab bar controller (and SwiftUI) still have the new one selected
		select(transition.fromTab, in: tabBarController)
		selection?.wrappedValue = transition.fromTab
	}

	private func select(_ tab: ContentView.Tab, in controller: UITabBarController) {
		if #available(iOS 18, *), controller.tabs.indices.contains(tab.index) {
			controller.selectedTab = controller.tabs[tab.index]
		} else {
			controller.selectedIndex = tab.index
		}
	}

	private func selectedTab(in controller: UITabBarController) -> ContentView.Tab? {
		let index: Int?
		if #available(iOS 18, *), !controller.tabs.isEmpty {
			index = controller.selectedTab.flatMap(controller.tabs.firstIndex(of:))
		} else {
			index = controller.selectedIndex
		}
		let tabs = ContentView.Tab.allCases
		return index.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil }
	}

	private func startDisplayLink() {
		guard displayLink == nil else { return }
		let link = CADisplayLink(target: self, selector: #selector(keepFrameRateUp(_:)))
		if #available(iOS 15, *) {
			link.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
		}
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	private func stopDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
	}

	/// The slide itself updates with each touch; this is only here so the screen keeps refreshing as often as it can meanwhile.
	@objc private func keepFrameRateUp(_ link: CADisplayLink) {}

	/// Returns once the tabs have stopped sliding (right away if they aren't), e.g. to hold off on reloads that would redraw a tab as it slides in.
	@MainActor
	func waitUntilSettled() async {
		while transition != nil, !Task.isCancelled {
			try? await Task.sleep(nanoseconds: 30_000_000)
		}
	}

	/// the screen showing in the given tab, i.e. the top of its navigation stack
	private func currentScreen(
		of tab: UIViewController,
		in controller: UITabBarController
	) -> (controller: UIViewController, isPushed: Bool)? {
		guard let navigation = Self.firstNavigationController(in: tab) else { return (tab, false) }
		// not while it's pushing or popping a screen (it also reports the tabs switching, which is fine)
		if let coordinator = navigation.transitionCoordinator, coordinator !== controller.transitionCoordinator {
			return nil
		}
		guard let top = navigation.topViewController else { return nil }
		return (top, navigation.viewControllers.count > 1)
	}

	private static func firstNavigationController(in root: UIViewController) -> UINavigationController? {
		var queue = [root]
		while !queue.isEmpty {
			let controller = queue.removeFirst()
			if let navigation = controller as? UINavigationController {
				return navigation
			}
			queue += controller.children
		}
		return nil
	}

	private func allowsSwiping(on screen: UIViewController) -> Bool {
		guard let screenView = screen.viewIfLoaded else { return false }
		return swipeAreas.allObjects.contains { $0.window != nil && $0.isDescendant(of: screenView) }
	}

	/// whether the touch landed on something that wants sideways drags for itself, like a horizontally scrolling view
	private func isInSidewaysControl(_ view: UIView?) -> Bool {
		var current = view
		while let view = current, view !== panRecognizer.view {
			switch view {
			case let scrollView as UIScrollView:
				let insets = scrollView.adjustedContentInset
				let scrollableWidth = scrollView.contentSize.width + insets.left + insets.right
				if scrollView.isScrollEnabled, scrollableWidth > scrollView.bounds.width + 1 {
					return true
				}
			case is UISlider, is UISwitch:
				return true
			default:
				break
			}
			current = view.superview
		}
		return false
	}
}

extension TabSwiper: UIGestureRecognizerDelegate {
	func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
		// leave the tab bar to its own gestures
		if let tabBar = tabBarController?.tabBar, !tabBar.isHidden, tabBar.window != nil,
		   tabBar.bounds.contains(touch.location(in: tabBar)) {
			return false
		}

		touchedView = touch.view
		return true
	}

	func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
		guard
			recognizer === panRecognizer,
			let controller = tabBarController,
			let selection,
			let view = recognizer.view
		else { return false }

		// the tab that's showing, or that the last swipe is settling on
		let current: (tab: ContentView.Tab, controller: UIViewController)
		if let transition {
			guard let settling = transition.settlingOn else { return false } // still following the finger
			current = settling
		} else {
			guard let selected = controller.selectedViewController else { return false }
			current = (selection.wrappedValue, selected)
		}

		var movement = panRecognizer.translation(in: view)
		if movement == .zero {
			movement = panRecognizer.velocity(in: view)
		}
		guard abs(movement.x) > abs(movement.y) else { return false } // mostly sideways, unlike scrolling

		guard
			let screen = currentScreen(of: current.controller, in: controller),
			allowsSwiping(on: screen.controller)
		else { return false }

		let isRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
		let movesForward = (movement.x < 0) != isRightToLeft
		// beyond a tab's main screen, swiping toward the previous tab means going back instead
		guard movesForward || !screen.isPushed else { return false }

		let tabs = ContentView.Tab.allCases
		let targetIndex = current.tab.index + (movesForward ? 1 : -1)
		guard tabs.indices.contains(targetIndex) else { return false }

		guard !isInSidewaysControl(touchedView) else { return false }

		// the new tab comes in from the side the finger is moving away from
		plannedSwitch = (tabs[targetIndex], movement.x < 0 ? 1 : -1)
		return true
	}

	func gestureRecognizer(
		_ recognizer: UIGestureRecognizer,
		shouldRequireFailureOf other: UIGestureRecognizer
	) -> Bool {
		// swiping list rows to reveal their actions (like deleting bookmarks) takes precedence
		String(describing: type(of: other)).contains("SwipeAction")
	}
}

/// Answers the tab bar controller's questions about transitions, and passes everything else on to the delegate SwiftUI set up.
private final class TabBarDelegateProxy: NSObject {
	weak var swiper: TabSwiper?
	weak var forwardee: UITabBarControllerDelegate?

	override func responds(to selector: Selector!) -> Bool {
		super.responds(to: selector) || forwardee?.responds(to: selector) == true
	}

	override func forwardingTarget(for selector: Selector!) -> Any? {
		if forwardee?.responds(to: selector) == true {
			return forwardee
		} else {
			return super.forwardingTarget(for: selector)
		}
	}
}

extension TabBarDelegateProxy: UITabBarControllerDelegate {
	func tabBarController(
		_ controller: UITabBarController,
		animationControllerForTransitionFrom fromController: UIViewController,
		to toController: UIViewController
	) -> UIViewControllerAnimatedTransitioning? {
		if let transition = swiper?.startingTransition {
			transition.isAccepted = true
			return transition
		} else {
			return forwardee?.tabBarController?(controller, animationControllerForTransitionFrom: fromController, to: toController)
		}
	}

	func tabBarController(
		_ controller: UITabBarController,
		interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
	) -> UIViewControllerInteractiveTransitioning? {
		if let transition = animationController as? TabSlideTransition {
			return transition
		} else {
			return forwardee?.tabBarController?(controller, interactionControllerFor: animationController)
		}
	}
}

/// What a slide that's cut short by a new swipe leaves behind for that one to pick up.
private struct TabSlideHandover {
	/// the view of the tab that's showing now
	var view: UIView
	/// how far it currently is off to the side
	var offset: CGFloat
	/// a stand-in for the neighboring tab while it's still partly in sight, along with where it is relative to `view`
	var neighbor: (view: UIView, offset: CGFloat)?
}

/// Slides the old tab out to one side while the new one comes in from the other, following the finger and then springing into place.
///
/// This only ever animates the views' layers rather than moving the views themselves, so nothing has to be laid out again mid-swipe.
private final class TabSlideTransition: NSObject {
	private static let animationKey = "tabSlide"

	let fromTab: ContentView.Tab
	let toTab: ContentView.Tab
	/// the side the new tab comes in from: 1 for the right, -1 for the left
	let edge: CGFloat
	var completion: ((_ didSwitch: Bool) -> Void)?
	/// whether the tab bar controller has taken this on to switch tabs with
	var isAccepted = false

	/// how far along the slide is, from 0 (old tab in place) to 1 (new tab in place)—or a little below 0 when picking up from an earlier slide that hadn't quite settled
	private(set) var progress: CGFloat = 0
	/// set once the finger lets go: whether it's settling on the new tab, rather than back on the old one
	private(set) var isSwitching: Bool?

	private var handover: TabSlideHandover?
	private var context: UIViewControllerContextTransitioning?
	private var fromController: UIViewController?
	private var toController: UIViewController?
	private var fromView: UIView?
	private var toView: UIView?
	/// a stand-in for the tab on the far side of the old one, left over from an earlier slide, which comes along until it's out of sight
	private var companion: (view: UIView, offset: CGFloat)?
	private var width: CGFloat = 1
	/// where the old tab's view started out
	private var startOffset: CGFloat = 0
	private var lowestProgress: CGFloat = 0
	private var translation: CGFloat = 0
	private var fingerVelocity: CGFloat = 0

	init(from fromTab: ContentView.Tab, to toTab: ContentView.Tab, edge: CGFloat, handover: TabSlideHandover?) {
		self.fromTab = fromTab
		self.toTab = toTab
		self.edge = edge
		self.handover = handover
	}

	/// the tab it's settling on (along with its view controller), once the finger has let go
	var settlingOn: (tab: ContentView.Tab, controller: UIViewController)? {
		guard context != nil, let isSwitching, let fromController, let toController else { return nil }
		return isSwitching ? (toTab, toController) : (fromTab, fromController)
	}

	/// - Parameter translation: how far the finger has moved sideways since this started
	func update(translation newTranslation: CGFloat) {
		guard isSwitching == nil else { return }
		translation = newTranslation
		guard let context else { return } // picked up once it starts
		progress = clampedProgress(forOffset: startOffset + translation)
		hold(at: progress)
		context.updateInteractiveTransition(min(max(progress, 0), 1))
	}

	/// - Parameter velocity: the finger's, in points per second
	func finish(switching shouldSwitch: Bool, velocity: CGFloat) {
		guard isSwitching == nil else { return }
		isSwitching = shouldSwitch
		fingerVelocity = velocity
		guard context != nil else { return } // settles once it starts
		settle()
	}

	/// Cuts the settling short for a new swipe: completes the transition right away, but leaves everything where it is on screen for the new slide to pick up.
	func interrupt() -> TabSlideHandover? {
		guard let context, let isSwitching, let fromView, let toView else { return nil }

		let fromOffset = Self.presentedOffset(of: fromView)
		let shownView = isSwitching ? toView : fromView
		let shownOffset = isSwitching ? fromOffset + edge * width : fromOffset

		// at most one other tab can still be in sight, on whichever side the shown one is moving away from
		var neighbor: (view: UIView, offset: CGFloat)?
		for (view, relativeOffset) in participants where view !== shownView {
			let offset = fromOffset + relativeOffset
			guard abs(offset) < width - 0.5 else { continue }

			let standIn: UIView
			if view === companion?.view {
				standIn = view
			} else if let snapshot = view.snapshotView(afterScreenUpdates: false) {
				// the tab bar controller is about to take the actual view away, so leave a snapshot in its place
				snapshot.frame = view.frame
				context.containerView.addSubview(snapshot)
				standIn = snapshot
			} else {
				continue
			}
			hold(standIn, at: offset)
			neighbor = (standIn, offset - shownOffset)
			break
		}
		hold(shownView, at: shownOffset)

		wrapUp(keeping: [shownView, neighbor?.view].compactMap { $0 })
		return .init(view: shownView, offset: shownOffset, neighbor: neighbor)
	}

	/// Puts back what this was going to pick up from an earlier slide, for when it doesn't happen after all.
	func abandon() {
		if let handover {
			discard(handover)
		}
		handover = nil
	}

	private func start(_ context: UIViewControllerContextTransitioning) {
		self.context = context
		let handover = self.handover
		self.handover = nil

		let container = context.containerView
		guard
			let fromController = context.viewController(forKey: .from),
			let toController = context.viewController(forKey: .to),
			let fromView = context.view(forKey: .from),
			let toView = context.view(forKey: .to)
		else {
			// nothing to slide (which shouldn't happen), so just switch
			if let handover {
				discard(handover)
			}
			if let toView = context.view(forKey: .to) {
				container.addSubview(toView)
			}
			if context.isInteractive {
				context.finishInteractiveTransition()
			}
			self.context = nil
			isSwitching = true
			context.completeTransition(true)
			completion?(true)
			return
		}

		width = max(container.bounds.width, 1)
		let finalFrame = context.finalFrame(for: toController)
		toView.frame = finalFrame.isEmpty ? container.bounds : finalFrame
		container.addSubview(toView)
		self.fromController = fromController
		self.toController = toController
		self.fromView = fromView
		self.toView = toView

		// pick up where the last slide left off, if it got cut short
		if let handover, handover.view === fromView {
			startOffset = handover.offset
			if let neighbor = handover.neighbor {
				if abs(neighbor.offset - edge * width) < 1 {
					// it's standing in for the tab that's coming in now, which can simply take its place
					neighbor.view.removeFromSuperview()
				} else {
					companion = neighbor
				}
			}
		} else if let handover {
			discard(handover)
		}
		lowestProgress = min(0, progress(forOffset: startOffset))
		progress = clampedProgress(forOffset: startOffset + translation)
		hold(at: progress)

		if isSwitching != nil {
			settle() // the finger already let go
		}
	}

	private func settle() {
		guard let context, let isSwitching else { return }

		if context.isInteractive {
			if isSwitching {
				context.finishInteractiveTransition()
			} else {
				context.cancelInteractiveTransition()
			}
		}

		let start = offset(at: progress)
		let end = offset(at: isSwitching ? 1 : 0)
		let distance = abs(end - start)
		// springs take their velocity relative to the distance left to go,
		// and this one won't overshoot (which would show a gap at the edge) as long as that stays below 20.
		let speedTowardEnd = (end - start) * fingerVelocity > 0 ? abs(fingerVelocity) : 0
		let springVelocity = distance < 0.5 ? 0 : min(speedTowardEnd / distance, 19)

		CATransaction.begin()
		CATransaction.setCompletionBlock { [self] in
			wrapUp()
		}
		for (view, relativeOffset) in participants {
			spring(view, from: start + relativeOffset, to: end + relativeOffset, velocity: springVelocity)
		}
		CATransaction.commit()
	}

	/// completes the transition and cleans up after it—apart from the given views, which the next slide takes over
	private func wrapUp(keeping keptViews: [UIView] = []) {
		guard let context, let isSwitching, let fromView, let toView else { return }
		let companion = self.companion
		self.context = nil
		self.fromView = nil
		self.toView = nil
		self.companion = nil

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		context.completeTransition(isSwitching)
		// UIKit should take care of this, but the tab that's no longer showing really shouldn't stick around
		let hiddenView = isSwitching ? fromView : toView
		if hiddenView.superview === context.containerView {
			hiddenView.removeFromSuperview()
		}
		for view in [fromView, toView] where !keptViews.contains(where: { $0 === view }) {
			view.layer.removeAnimation(forKey: Self.animationKey)
		}
		if let companion, !keptViews.contains(where: { $0 === companion.view }) {
			companion.view.removeFromSuperview()
		}
		CATransaction.commit()

		completion?(isSwitching)
	}

	private func discard(_ handover: TabSlideHandover) {
		handover.view.layer.removeAnimation(forKey: Self.animationKey)
		handover.neighbor?.view.removeFromSuperview()
	}

	/// the views that slide, along with where they are relative to the old tab's view
	private var participants: [(view: UIView, offset: CGFloat)] {
		guard let fromView, let toView else { return [] }
		var participants: [(view: UIView, offset: CGFloat)] = [(fromView, 0), (toView, edge * width)]
		if let companion {
			participants.append(companion)
		}
		return participants
	}

	/// where the old tab's view is at the given progress
	private func offset(at progress: CGFloat) -> CGFloat {
		-edge * progress * width
	}

	private func progress(forOffset offset: CGFloat) -> CGFloat {
		-edge * offset / width
	}

	private func clampedProgress(forOffset offset: CGFloat) -> CGFloat {
		min(max(progress(forOffset: offset), lowestProgress), 1)
	}

	/// keeps everything at the given point of the slide, until the next update
	private func hold(at progress: CGFloat) {
		let offset = offset(at: progress)
		for (view, relativeOffset) in participants {
			hold(view, at: offset + relativeOffset)
		}
	}

	private func hold(_ view: UIView, at offset: CGFloat) {
		let animation = CABasicAnimation(keyPath: "position.x")
		animation.fromValue = offset
		animation.toValue = offset
		animation.duration = 1 // it stays put after that anyway
		configure(animation)
		view.layer.add(animation, forKey: Self.animationKey)
	}

	private func spring(_ view: UIView, from start: CGFloat, to end: CGFloat, velocity: CGFloat) {
		let animation = CASpringAnimation(keyPath: "position.x")
		// critically damped (so it never overshoots), settling about like SwiftUI's .spring(response: 0.3)
		animation.mass = 1
		animation.stiffness = 400
		animation.damping = 40
		animation.initialVelocity = velocity
		animation.fromValue = start
		animation.toValue = end
		// the last stretch of settling is well under a point, so there's no need to wait for it
		animation.duration = min(animation.settlingDuration, 0.45)
		if #available(iOS 15, *) {
			animation.preferredFrameRateRange = .init(minimum: 80, maximum: 120, preferred: 120)
		}
		configure(animation)
		view.layer.add(animation, forKey: Self.animationKey)
	}

	/// makes the animation offset the layer from where it actually is, and stay there once done
	private func configure(_ animation: CABasicAnimation) {
		animation.isAdditive = true
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
	}

	/// how far the view currently appears off to the side, mid-animation
	private static func presentedOffset(of view: UIView) -> CGFloat {
		guard let presented = view.layer.presentation() else { return 0 }
		return presented.position.x - view.layer.position.x
	}
}

extension TabSlideTransition: UIViewControllerAnimatedTransitioning {
	func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
		0.4
	}

	func animateTransition(using context: UIViewControllerContextTransitioning) {
		// only used if UIKit decides to run this non-interactively after all
		start(context)
		finish(switching: true, velocity: 0)
	}
}

extension TabSlideTransition: UIViewControllerInteractiveTransitioning {
	var wantsInteractiveStart: Bool { true }

	func startInteractiveTransition(_ context: UIViewControllerContextTransitioning) {
		start(context)
	}
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		ContentView(accountManager: .mocked, assetManager: .forPreviews, settings: .init(), store: .init())
		ContentView(accountManager: .mocked, assetManager: .forPreviews, settings: .init(), store: .init(), tab: .live)
		ContentView(accountManager: .mocked, assetManager: .forPreviews, settings: .init(), store: .init(), tab: .reference)
		ContentView(accountManager: .init(), assetManager: .forPreviews, settings: .init(), store: .init())
	}
}
#endif
