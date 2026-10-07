import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI

/// A grid of video messages ("circles") that turns into a vertical feed while one of them is playing.
///
/// Playback itself is owned by the shared media manager: tapping a circle asks the host to start a `.custom`
/// voice playlist at that message, and the grid follows `globalMediaPlayerState`. The switch between the two
/// modes is a zoom: the tapped circle grows from its cell into the large feed circle (and shrinks back on
/// close) while the rest of the grid dissolves away from it and the feed's neighbours settle in around it, the
/// way a system zoom transition treats its source view. Inside the feed every item's diameter follows its
/// distance from the presented position, so the neighbours grow in place while the user scrolls. One unit of
/// content offset is one item; the scroll snaps one item per swipe, and the circle that crosses the midpoint
/// between two items becomes the playing one at once. Closing the playlist zooms the feed back into the grid.
public final class CirclesGridNode: ASDisplayNode, ASScrollViewDelegate {
    private struct Params {
        var size: CGSize
        var topInset: CGFloat
        var sideInset: CGFloat
        var bottomInset: CGFloat
        var visibleHeight: CGFloat
        var isScrollingLockedAtTop: Bool
        var presentationData: PresentationData
    }

    private struct GridMetrics {
        var columns: Int
        var edgeInset: CGFloat
        var spacing: CGFloat
        var itemSize: CGFloat

        init(availableWidth: CGFloat) {
            self.columns = max(3, min(6, Int(availableWidth / 140.0)))
            self.edgeInset = 8.0
            self.spacing = 6.0
            self.itemSize = floor((availableWidth - self.edgeInset * 2.0 - self.spacing * CGFloat(self.columns - 1)) / CGFloat(self.columns))
        }
    }

    private struct FeedMetrics {
        var smallDiameter: CGFloat
        var largeDiameter: CGFloat
        /// Vertical distance between neighbouring circles.
        var gap: CGFloat
        /// Content offset per item.
        var unit: CGFloat
        /// Center of the visible area, in the node's coordinates (the content scrolls under the insets).
        var visibleCenterY: CGFloat

        init(availableWidth: CGFloat, viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, smallDiameter: CGFloat) {
            self.smallDiameter = smallDiameter
            self.largeDiameter = min(availableWidth - 40.0, 420.0)
            self.gap = 32.0
            self.unit = self.largeDiameter + self.gap
            self.visibleCenterY = topInset + max(0.0, viewportHeight - topInset - bottomInset) * 0.5
        }

        func contentOffset(forIndex index: Int) -> CGFloat {
            return CGFloat(index) * self.unit
        }
    }

    private struct ItemGeometry {
        var frame: CGRect
        var progress: CGFloat
    }

    private enum Mode: Equatable {
        case grid
        case feed
    }

    /// The zoom between the grid and the feed: one spring for the growing circle, the departing content and
    /// the arriving content alike.
    private static let zoomTransition: ContainedViewLayoutTransition = .animated(duration: 0.5, curve: .customSpring(mass: 1.0, stiffness: 300.0, damping: 30.0, initialVelocity: 0.0))
    /// How far the content that leaves (the grid on opening, the feed on closing) is pushed away from the
    /// zoomed circle while it fades, and where the arriving content fades in from.
    private static let zoomDepartingScale: CGFloat = 1.15
    private static let zoomArrivingScale: CGFloat = 0.85
    private static let zoomFadeDuration: Double = 0.3
    /// Dimming of the feed's neighbours relative to the presented circle.
    private static let neighbourContentAlpha: CGFloat = 0.5

    private let context: AccountContext
    private let scrollNode: ASScrollNode

    private var _itemInteraction: CircleItemInteraction?
    private var itemInteraction: CircleItemInteraction {
        return self._itemInteraction!
    }

    private var params: Params?
    private var items: [CircleItem] = []
    private var itemNodes: [UInt32: CircleItemNode] = [:]
    private var mode: Mode = .grid
    /// The mode the metrics and content size currently describe; `mode` runs ahead of it until `applyMode`.
    private var layoutMode: Mode = .grid
    private var gridMetrics: GridMetrics?
    private var feedMetrics: FeedMetrics?
    private var contentHeight: CGFloat = 0.0

    private var playingMessageId: EngineMessage.Id?
    /// The item that is (or is about to be) playing: it is centered in the feed and owns the embedded player.
    /// It is set ahead of the media manager (on tap, on crossing the midpoint while scrolling) so the player
    /// node exists before playback starts and the overlay mini player never gets a chance to appear.
    private var presentedIndex: Int?
    /// Remembered when the feed collapses, so the grid scrolls to the circle that was playing.
    private var lastPresentedIndexForGrid: Int?
    private var isVisibleValue: Bool = true
    private var isZooming: Bool = false
    /// Set while `applyMode` moves the content offset, so the scroll callback does not relayout (and drop)
    /// the nodes the zoom is about to snapshot.
    private var isApplyingMode: Bool = false
    private var zoomSnapshotView: UIView?
    /// True from the start of a drag until the resulting deceleration settles: playback follows the finger
    /// then, and the grid must not scroll programmatically in response to the playlist change it caused.
    private var isUserScrolling: Bool = false

    private var playbackStateDisposable: Disposable?

    private let ready = Promise<Bool>()
    private var didSetReady: Bool = false
    public var isReady: Signal<Bool, NoError> {
        return self.ready.get()
    }

    public var loadMore: (() -> Void)?
    public var beganInteractiveDragging: (() -> Void)?

    public var selectedMessageIds: Set<EngineMessage.Id>? {
        didSet {
            self.itemInteraction.selectedMessageIds = self.selectedMessageIds
        }
    }

    /// - Parameters:
    ///   - openMessage: start playback of the message through a `.custom` voice playlist.
    ///   - messageContextAction: present the message context menu from the extracted source node.
    ///   - navigateToMessage: open the message in its chat.
    public init(
        context: AccountContext,
        openMessage: @escaping (EngineRawMessage) -> Void,
        messageContextAction: @escaping (EngineRawMessage, ContextExtractedContentContainingNode, CGRect, ContextGesture?) -> Void,
        toggleMessageSelection: @escaping (EngineMessage.Id, Bool) -> Void,
        navigateToMessage: @escaping (EngineRawMessage) -> Void
    ) {
        self.context = context
        self.scrollNode = ASScrollNode()

        super.init()

        self._itemInteraction = CircleItemInteraction(
            openMessage: { [weak self] message in
                guard let self else {
                    return
                }
                // Warm the tapped item up as the presented one before the playlist starts.
                if let index = self.items.firstIndex(where: { $0.message.id == message.id }) {
                    self.presentedIndex = index
                    self.updateVisibleItems(transition: .immediate)
                }
                openMessage(message)
            },
            togglePlayPause: {
                context.sharedContext.mediaManager.playlistControl(.playback(.togglePlayPause), type: .voice)
            },
            openMessageContextActions: messageContextAction,
            toggleSelection: toggleMessageSelection,
            navigateToMessage: navigateToMessage
        )

        self.scrollNode.view.delaysContentTouches = false
        self.scrollNode.view.canCancelContentTouches = true
        self.scrollNode.view.showsVerticalScrollIndicator = false
        self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        self.scrollNode.view.scrollsToTop = false
        self.scrollNode.view.delegate = self.wrappedScrollViewDelegate
        self.addSubnode(self.scrollNode)

        self.playbackStateDisposable = (context.sharedContext.mediaManager.globalMediaPlayerState
        |> deliverOnMainQueue).startStrict(next: { [weak self] value in
            guard let self else {
                return
            }
            var playingMessageId: EngineMessage.Id?
            if let (account, stateOrLoading, type) = value, account.id == context.account.id, case .voice = type, case let .state(state) = stateOrLoading {
                if let playlistId = state.playlistId as? PeerMessagesMediaPlaylistId, case .custom = playlistId, let itemId = state.item.id as? PeerMessagesMediaPlaylistItemId, state.item.playbackData?.type == .instantVideo {
                    playingMessageId = itemId.messageId
                }
            }
            self.updatePlayingMessageId(playingMessageId)
        })
    }

    deinit {
        self.playbackStateDisposable?.dispose()
    }

    public var isInFeedMode: Bool {
        return self.mode == .feed
    }

    /// Replaces the displayed messages. Anything that is not a video message is ignored.
    public func updateMessages(_ messages: [EngineRawMessage]) {
        let presentedMessageId = self.presentedIndex.flatMap { $0 < self.items.count ? self.items[$0].message.id : nil }

        var items: [CircleItem] = []
        var seenIds = Set<UInt32>()
        for message in messages {
            if let item = CircleItem(message: message), !seenIds.contains(item.stableId) {
                seenIds.insert(item.stableId)
                items.append(item)
            }
        }
        self.items = items

        if let presentedMessageId {
            self.presentedIndex = items.firstIndex(where: { $0.message.id == presentedMessageId })
        }
        let previousMode = self.mode
        self.mode = self.modeForPlayingMessage()
        if previousMode != self.mode, case .grid = self.mode {
            self.lastPresentedIndexForGrid = self.presentedIndex
            self.presentedIndex = nil
        }
        if self.params != nil {
            self.applyMode(centerPresented: previousMode != self.mode, transition: previousMode != self.mode ? CirclesGridNode.zoomTransition : .immediate)
        }
        if !self.didSetReady {
            self.didSetReady = true
            self.ready.set(.single(true))
        }
    }

    public func update(size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, presentationData: PresentationData, synchronous: Bool, transition: ContainedViewLayoutTransition) {
        let previousParams = self.params
        self.params = Params(size: size, topInset: topInset, sideInset: sideInset, bottomInset: bottomInset, visibleHeight: visibleHeight, isScrollingLockedAtTop: isScrollingLockedAtTop, presentationData: presentationData)

        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: size))

        let geometryChanged = previousParams?.size != size || previousParams?.topInset != topInset || previousParams?.sideInset != sideInset || previousParams?.bottomInset != bottomInset
        self.applyMode(centerPresented: geometryChanged, synchronous: synchronous, transition: geometryChanged && previousParams != nil ? transition : .immediate)

        if isScrollingLockedAtTop, case .grid = self.mode {
            if self.scrollNode.view.contentOffset.y > .ulpOfOne {
                transition.updateBounds(node: self.scrollNode, bounds: CGRect(origin: CGPoint(), size: self.scrollNode.bounds.size))
            }
        }
        self.scrollNode.view.isScrollEnabled = !isScrollingLockedAtTop || self.isInFeedMode
    }

    /// Tells the grid whether it is on screen. A hidden grid releases the embedded player, so the overlay
    /// player shows the circle instead; it takes the content back once visible again.
    public func updateIsVisible(_ isVisible: Bool) {
        if self.isVisibleValue == isVisible {
            return
        }
        self.isVisibleValue = isVisible
        self.updateVisibleItems(transition: .immediate)
    }

    public func scrollToTop() -> Bool {
        if case .grid = self.mode, self.scrollNode.view.contentOffset.y > 0.0 {
            self.scrollNode.view.setContentOffset(CGPoint(), animated: true)
            return true
        }
        return false
    }

    public func findLoadedMessage(id: EngineMessage.Id) -> EngineRawMessage? {
        for item in self.items {
            if item.message.id == id {
                return item.message
            }
        }
        return nil
    }

    public func updateSelectedMessages(animated: Bool) {
        for (_, itemNode) in self.itemNodes {
            itemNode.updateSelectionState(animated: animated)
        }
    }

    public func cancelPreviewGestures() {
        for (_, itemNode) in self.itemNodes {
            itemNode.cancelPreviewGesture()
        }
    }

    public func ensureMessageIsVisible(id: EngineMessage.Id) {
        guard let index = self.items.firstIndex(where: { $0.message.id == id }), let params = self.params else {
            return
        }
        switch self.mode {
        case .grid:
            let frame = self.gridFrame(index: index)
            if !self.scrollNode.view.bounds.contains(frame) {
                self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: self.clampedContentOffset(frame.midY - params.size.height * 0.5)), animated: true)
            }
        case .feed:
            self.scrollToItem(index: index, animated: true)
        }
    }

    public func transitionNodeForGallery(messageId: EngineMessage.Id, media: EngineRawMedia) -> (ASDisplayNode, CGRect, () -> (UIView?, UIView?))? {
        for item in self.items {
            if item.message.id == messageId {
                return self.itemNodes[item.stableId]?.transitionNode()
            }
        }
        return nil
    }

    public func addToTransitionSurface(view: UIView) {
        self.scrollNode.view.addSubview(view)
    }

    // MARK: - Playback

    private func modeForPlayingMessage() -> Mode {
        guard let playingMessageId = self.playingMessageId, self.items.contains(where: { $0.message.id == playingMessageId }) else {
            return .grid
        }
        return .feed
    }

    private func updatePlayingMessageId(_ id: EngineMessage.Id?) {
        if self.playingMessageId == id {
            return
        }
        self.playingMessageId = id
        let playingIndex = id.flatMap { id in self.items.firstIndex(where: { $0.message.id == id }) }
        let previousMode = self.mode
        self.mode = self.modeForPlayingMessage()
        guard self.params != nil else {
            self.presentedIndex = playingIndex
            return
        }
        switch (previousMode, self.mode) {
        case (.grid, .feed):
            if self.presentedIndex != playingIndex {
                self.presentedIndex = playingIndex
            }
            self.applyMode(centerPresented: true, transition: CirclesGridNode.zoomTransition)
        case (.feed, .grid):
            self.lastPresentedIndexForGrid = self.presentedIndex
            self.presentedIndex = nil
            self.applyMode(centerPresented: true, transition: CirclesGridNode.zoomTransition)
        case (.feed, .feed):
            // The playlist moved on its own (auto-advance, or the header's next/previous): follow it, unless
            // the change was caused by the user scrolling, in which case the feed is already there.
            if let playingIndex, playingIndex != self.presentedIndex, !self.isUserScrolling {
                self.presentedIndex = playingIndex
                self.scrollToItem(index: playingIndex, animated: true)
            }
            self.updateVisibleItems(transition: .immediate)
        case (.grid, .grid):
            self.presentedIndex = nil
            self.updateVisibleItems(transition: .immediate)
        }
    }

    /// The item nearest to the center becomes the presented (playing) one.
    private func presentItemNearestToCenter() {
        guard case .feed = self.mode, let feedMetrics = self.feedMetrics, !self.items.isEmpty else {
            return
        }
        let index = self.nearestIndex(toContentOffset: self.scrollNode.view.contentOffset.y, feedMetrics: feedMetrics)
        if self.presentedIndex != index {
            self.presentedIndex = index
            self.updateVisibleItems(transition: .immediate)
            self.itemInteraction.openMessage(self.items[index].message)
        }
    }

    private func nearestIndex(toContentOffset offset: CGFloat, feedMetrics: FeedMetrics) -> Int {
        return max(0, min(self.items.count - 1, Int((offset / feedMetrics.unit).rounded())))
    }

    private func scrollToItem(index: Int, animated: Bool) {
        guard let feedMetrics = self.feedMetrics else {
            return
        }
        let offset = self.clampedContentOffset(feedMetrics.contentOffset(forIndex: index))
        self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: offset), animated: animated)
    }

    // MARK: - Layout

    private func clampedContentOffset(_ offset: CGFloat) -> CGFloat {
        guard let params = self.params else {
            return 0.0
        }
        return max(0.0, min(offset, max(0.0, self.contentHeight - params.size.height)))
    }

    private func gridFrame(index: Int) -> CGRect {
        guard let params = self.params, let metrics = self.gridMetrics else {
            return CGRect()
        }
        let row = index / metrics.columns
        let column = index % metrics.columns
        return CGRect(origin: CGPoint(x: params.sideInset + metrics.edgeInset + CGFloat(column) * (metrics.itemSize + metrics.spacing), y: params.topInset + metrics.edgeInset + CGFloat(row) * (metrics.itemSize + metrics.spacing)), size: CGSize(width: metrics.itemSize, height: metrics.itemSize))
    }

    /// Feed geometry for a content offset: `t = offset / unit` is the fractional presented position, every
    /// item's diameter follows its distance from `t`, the circles are stacked from those diameters, and the
    /// stack is placed so that the (interpolated) center of item `t` sits at the visible center. Neighbours
    /// therefore stay attached to the large circle and grow in place as it scrolls.
    private func feedGeometry(contentOffset: CGFloat, feedMetrics: FeedMetrics) -> [ItemGeometry] {
        guard let params = self.params, !self.items.isEmpty else {
            return []
        }
        let count = self.items.count
        let t = max(0.0, min(CGFloat(count - 1), contentOffset / feedMetrics.unit))

        var diameters: [CGFloat] = []
        var progresses: [CGFloat] = []
        diameters.reserveCapacity(count)
        progresses.reserveCapacity(count)
        for index in 0 ..< count {
            let progress = max(0.0, 1.0 - min(1.0, abs(CGFloat(index) - t)))
            let eased = progress * progress * (3.0 - 2.0 * progress)
            diameters.append(feedMetrics.smallDiameter + (feedMetrics.largeDiameter - feedMetrics.smallDiameter) * eased)
            progresses.append(progress)
        }

        var tops: [CGFloat] = []
        tops.reserveCapacity(count)
        var currentY: CGFloat = 0.0
        for index in 0 ..< count {
            tops.append(currentY)
            currentY += diameters[index] + feedMetrics.gap
        }

        let lowerIndex = Int(floor(t))
        let upperIndex = min(count - 1, lowerIndex + 1)
        let fraction = t - CGFloat(lowerIndex)
        let lowerCenter = tops[lowerIndex] + diameters[lowerIndex] * 0.5
        let upperCenter = tops[upperIndex] + diameters[upperIndex] * 0.5
        let presentedCenter = lowerCenter * (1.0 - fraction) + upperCenter * fraction
        let baseY = contentOffset + feedMetrics.visibleCenterY - presentedCenter

        var result: [ItemGeometry] = []
        result.reserveCapacity(count)
        for index in 0 ..< count {
            let diameter = diameters[index]
            let x = params.sideInset + floor((params.size.width - params.sideInset * 2.0 - diameter) * 0.5)
            result.append(ItemGeometry(frame: CGRect(origin: CGPoint(x: x, y: baseY + tops[index]), size: CGSize(width: diameter, height: diameter)), progress: progresses[index]))
        }
        return result
    }

    private func geometries(mode: Mode, contentOffset: CGFloat) -> [ItemGeometry] {
        switch mode {
        case .grid:
            guard self.gridMetrics != nil else {
                return []
            }
            return (0 ..< self.items.count).map { ItemGeometry(frame: self.gridFrame(index: $0), progress: 0.0) }
        case .feed:
            guard let feedMetrics = self.feedMetrics else {
                return []
            }
            return self.feedGeometry(contentOffset: contentOffset, feedMetrics: feedMetrics)
        }
    }

    private func visibleIndices(geometries: [ItemGeometry], contentOffset: CGFloat) -> [Int] {
        guard let params = self.params else {
            return []
        }
        let preload: CGFloat = params.size.height * 0.5
        let visibleRect = CGRect(x: 0.0, y: contentOffset - preload, width: params.size.width, height: params.size.height + preload * 2.0)
        var result: [Int] = []
        for (index, geometry) in geometries.enumerated() where geometry.frame.intersects(visibleRect) {
            result.append(index)
        }
        return result
    }

    private func onScreenIndices(geometries: [ItemGeometry], contentOffset: CGFloat) -> [Int] {
        guard let params = self.params else {
            return []
        }
        let visibleRect = CGRect(x: 0.0, y: contentOffset - 40.0, width: params.size.width, height: params.size.height + 80.0)
        var result: [Int] = []
        for (index, geometry) in geometries.enumerated() where geometry.frame.intersects(visibleRect) {
            result.append(index)
        }
        return result
    }

    /// Recomputes metrics and content size for the current mode and moves the items into place. When the
    /// mode changed, the presented item is centered by jumping the content offset and the change is shown
    /// as a zoom around that item.
    private func applyMode(centerPresented: Bool, synchronous: Bool = false, transition: ContainedViewLayoutTransition) {
        guard let params = self.params else {
            return
        }
        let previousMode = self.layoutMode
        let previousOffset = self.scrollNode.view.contentOffset.y
        let previousGeometries = self.geometries(mode: previousMode, contentOffset: previousOffset)
        let previousOnScreen = self.onScreenIndices(geometries: previousGeometries, contentOffset: previousOffset)

        let availableWidth = params.size.width - params.sideInset * 2.0
        let gridMetrics = GridMetrics(availableWidth: availableWidth)
        self.gridMetrics = gridMetrics

        var zoomIndex: Int?
        var targetOffset = previousOffset
        switch self.mode {
        case .grid:
            self.feedMetrics = nil
            let rows = (self.items.count + gridMetrics.columns - 1) / gridMetrics.columns
            self.contentHeight = params.topInset + gridMetrics.edgeInset * 2.0 + CGFloat(rows) * gridMetrics.itemSize + CGFloat(max(0, rows - 1)) * gridMetrics.spacing + params.bottomInset
            if centerPresented, let index = self.lastPresentedIndexForGrid, index < self.items.count {
                zoomIndex = index
                targetOffset = self.gridFrame(index: index).midY - (params.topInset + max(0.0, params.size.height - params.topInset - params.bottomInset) * 0.5)
            }
            self.lastPresentedIndexForGrid = nil
            self.scrollNode.view.decelerationRate = .normal
        case .feed:
            let feedMetrics = FeedMetrics(availableWidth: availableWidth, viewportHeight: params.size.height, topInset: params.topInset, bottomInset: params.bottomInset, smallDiameter: gridMetrics.itemSize)
            self.feedMetrics = feedMetrics
            self.contentHeight = CGFloat(max(0, self.items.count - 1)) * feedMetrics.unit + params.size.height
            if centerPresented, let presentedIndex = self.presentedIndex {
                zoomIndex = presentedIndex
                targetOffset = feedMetrics.contentOffset(forIndex: presentedIndex)
            }
            self.scrollNode.view.decelerationRate = .fast
        }
        self.layoutMode = self.mode
        self.isApplyingMode = true
        self.scrollNode.view.contentSize = CGSize(width: params.size.width, height: self.contentHeight)
        targetOffset = self.clampedContentOffset(targetOffset)
        if abs(targetOffset - previousOffset) > .ulpOfOne {
            self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: false)
        }
        self.isApplyingMode = false

        if transition.isAnimated, previousMode != self.mode, let zoomIndex, zoomIndex < previousGeometries.count {
            self.performZoom(index: zoomIndex, previousGeometries: previousGeometries, previousOnScreen: previousOnScreen, offsetDelta: targetOffset - previousOffset, synchronous: synchronous, transition: transition)
        } else if transition.isAnimated {
            // Same mode, new geometry (rotation, insets): move everything that is on screen.
            var previousFrames: [Int: CGRect] = [:]
            for index in previousOnScreen where index < previousGeometries.count {
                previousFrames[index] = previousGeometries[index].frame.offsetBy(dx: 0.0, dy: targetOffset - previousOffset)
            }
            self.updateVisibleItems(transition: transition, previousFrames: previousFrames, synchronous: synchronous)
        } else {
            self.updateVisibleItems(transition: .immediate, synchronous: synchronous)
        }
    }

    /// The zoom between the modes, around item `index` (the tapped circle on opening, the playing one on
    /// closing). The circle itself animates from its old frame to its new one. Everything else that was on
    /// screen is replaced by a snapshot that fades while being pushed away from the circle; everything that
    /// is on screen in the new mode fades in while settling in from the opposite direction.
    private func performZoom(index: Int, previousGeometries: [ItemGeometry], previousOnScreen: [Int], offsetDelta: CGFloat, synchronous: Bool, transition: ContainedViewLayoutTransition) {
        guard let params = self.params, case let .animated(duration, curve) = transition else {
            self.updateVisibleItems(transition: .immediate, synchronous: synchronous)
            return
        }
        let contentOffset = self.scrollNode.view.contentOffset.y
        let isOpening = self.mode == .feed
        let departingScale = isOpening ? CirclesGridNode.zoomDepartingScale : CirclesGridNode.zoomArrivingScale
        let arrivingScale = isOpening ? CirclesGridNode.zoomArrivingScale : CirclesGridNode.zoomDepartingScale

        self.zoomSnapshotView?.removeFromSuperview()
        self.zoomSnapshotView = nil

        // Departing content: snapshots of the other circles, where they were (the content offset jumped).
        let viewportFrame = CGRect(origin: CGPoint(x: 0.0, y: contentOffset), size: params.size)
        let snapshotContainer = UIView(frame: viewportFrame)
        snapshotContainer.isUserInteractionEnabled = false
        let padding = CircleItemNode.blurPadding
        for itemIndex in previousOnScreen where itemIndex != index && itemIndex < previousGeometries.count {
            guard let itemNode = self.itemNodes[self.items[itemIndex].stableId] else {
                continue
            }
            let captureRect = itemNode.bounds.insetBy(dx: -padding, dy: -padding)
            guard let snapshot = itemNode.view.resizableSnapshotView(from: captureRect, afterScreenUpdates: false, withCapInsets: UIEdgeInsets()) else {
                continue
            }
            let frame = previousGeometries[itemIndex].frame.offsetBy(dx: 0.0, dy: offsetDelta - viewportFrame.minY).insetBy(dx: -padding, dy: -padding)
            snapshot.frame = frame
            snapshotContainer.addSubview(snapshot)
        }
        self.scrollNode.view.insertSubview(snapshotContainer, at: 0)
        self.zoomSnapshotView = snapshotContainer

        let sourceFrame = previousGeometries[index].frame.offsetBy(dx: 0.0, dy: offsetDelta)
        let newGeometries = self.geometries(mode: self.mode, contentOffset: contentOffset)
        let targetFrame = index < newGeometries.count ? newGeometries[index].frame : sourceFrame
        // The zoom is anchored where the circle is on its way: the circle's center at the end of the zoom
        // for arriving content, at the start for departing content.
        let departingAnchor = CGPoint(x: sourceFrame.midX - viewportFrame.minX, y: sourceFrame.midY - viewportFrame.minY)
        snapshotContainer.layer.anchorPoint = CGPoint(x: departingAnchor.x / viewportFrame.width, y: departingAnchor.y / viewportFrame.height)
        snapshotContainer.layer.position = CGPoint(x: viewportFrame.minX + departingAnchor.x, y: viewportFrame.minY + departingAnchor.y)
        snapshotContainer.layer.animateScale(from: 1.0, to: departingScale, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: false)
        snapshotContainer.layer.animateAlpha(from: 1.0, to: 0.0, duration: CirclesGridNode.zoomFadeDuration, removeOnCompletion: false, completion: { [weak self, weak snapshotContainer] _ in
            snapshotContainer?.removeFromSuperview()
            if let self, self.zoomSnapshotView === snapshotContainer {
                self.zoomSnapshotView = nil
            }
        })

        self.isZooming = true
        self.updateVisibleItems(transition: transition, zoom: (index: index, sourceFrame: sourceFrame, anchor: CGPoint(x: targetFrame.midX, y: targetFrame.midY), arrivingScale: arrivingScale), synchronous: synchronous)
        Queue.mainQueue().after(duration) { [weak self] in
            guard let self else {
                return
            }
            self.isZooming = false
            self.updateVisibleItems(transition: .immediate)
        }
    }

    private func updateVisibleItems(transition: ContainedViewLayoutTransition, previousFrames: [Int: CGRect] = [:], zoom: (index: Int, sourceFrame: CGRect, anchor: CGPoint, arrivingScale: CGFloat)? = nil, synchronous: Bool = false) {
        guard let params = self.params else {
            return
        }
        let contentOffset = self.scrollNode.view.contentOffset.y
        let geometries = self.geometries(mode: self.layoutMode, contentOffset: contentOffset)

        var indexSet = Set(self.visibleIndices(geometries: geometries, contentOffset: contentOffset))
        if let presentedIndex = self.presentedIndex, presentedIndex < geometries.count {
            indexSet.insert(presentedIndex)
        }
        if let zoom, zoom.index < geometries.count {
            indexSet.insert(zoom.index)
        }

        let activeRect = self.scrollNode.view.bounds
        var validIds = Set<UInt32>()
        for index in indexSet.sorted() {
            let item = self.items[index]
            let geometry = geometries[index]
            validIds.insert(item.stableId)

            let itemNode: CircleItemNode
            var isNewNode = false
            if let current = self.itemNodes[item.stableId] {
                itemNode = current
            } else {
                isNewNode = true
                itemNode = CircleItemNode(context: self.context, interaction: self.itemInteraction)
                self.itemNodes[item.stableId] = itemNode
                self.scrollNode.addSubnode(itemNode)
            }

            itemNode.update(item: item, presentationData: params.presentationData, synchronousLoad: synchronous && geometry.frame.intersects(activeRect))

            let isPresented = index == self.presentedIndex
            let blurRadius: CGFloat
            let contentAlpha: CGFloat
            switch self.layoutMode {
            case .grid:
                blurRadius = 0.0
                contentAlpha = 1.0
            case .feed:
                blurRadius = isPresented ? 0.0 : 16.0 * (1.0 - geometry.progress)
                contentAlpha = CirclesGridNode.neighbourContentAlpha + (1.0 - CirclesGridNode.neighbourContentAlpha) * geometry.progress
            }

            let isZoomedItem = zoom?.index == index
            // Only the zoomed circle morphs during a zoom; the rest is laid out at once and faded in.
            let itemTransition: ContainedViewLayoutTransition = (zoom == nil || isZoomedItem) ? transition : .immediate
            // The embedded player stays attached as long as the grid is on screen, even while its circle is
            // scrolled away, so the overlay mini player never flashes during scrolling or the mode switch.
            itemNode.frame = geometry.frame
            itemNode.updateLayout(diameter: geometry.frame.width, progress: geometry.progress, blurRadius: blurRadius, contentAlpha: contentAlpha, isPlaying: isPresented, isAttached: self.isVisibleValue, transition: itemTransition)

            if let zoom {
                if isZoomedItem {
                    transition.animateFrame(layer: itemNode.layer, from: zoom.sourceFrame)
                    if isNewNode {
                        itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: CirclesGridNode.zoomFadeDuration)
                    }
                } else if geometry.frame.intersects(activeRect.insetBy(dx: 0.0, dy: -40.0)) {
                    // Arriving content settles in from a scaled position around the zoomed circle.
                    let center = CGPoint(x: geometry.frame.midX, y: geometry.frame.midY)
                    let fromCenter = CGPoint(x: zoom.anchor.x + (center.x - zoom.anchor.x) * zoom.arrivingScale, y: zoom.anchor.y + (center.y - zoom.anchor.y) * zoom.arrivingScale)
                    itemNode.layer.removeAllAnimations()
                    transition.animatePosition(layer: itemNode.layer, from: fromCenter, to: center)
                    transition.animateTransformScale(layer: itemNode.layer, from: CGPoint(x: zoom.arrivingScale, y: zoom.arrivingScale))
                    itemNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: CirclesGridNode.zoomFadeDuration)
                }
            } else if transition.isAnimated, let previousFrame = previousFrames[index] {
                transition.animateFrame(layer: itemNode.layer, from: previousFrame)
            }
            if isPresented || isZoomedItem {
                self.scrollNode.view.bringSubviewToFront(itemNode.view)
            }
        }

        var removedIds: [UInt32] = []
        for (id, itemNode) in self.itemNodes where !validIds.contains(id) {
            removedIds.append(id)
            itemNode.removeFromSupernode()
        }
        for id in removedIds {
            self.itemNodes.removeValue(forKey: id)
        }
    }

    // MARK: - ASScrollViewDelegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.isUserScrolling = true
        for (_, itemNode) in self.itemNodes {
            itemNode.cancelPreviewGesture()
        }
        self.beganInteractiveDragging?()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if self.isApplyingMode {
            return
        }
        if !self.isZooming {
            self.updateVisibleItems(transition: .immediate)
            // Playback follows the finger: once the scroll crosses the midpoint between two items, the circle
            // leaving the center stops and the one arriving starts, without waiting for the snap to settle.
            if self.isUserScrolling {
                self.presentItemNearestToCenter()
            }
        }
        if scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.bounds.height * 2.0 {
            self.loadMore?()
        }
    }

    /// Magnetic paging: the drag settles on the item nearest to where the deceleration would end, at most one
    /// item away from the current one.
    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard case .feed = self.mode, let feedMetrics = self.feedMetrics, !self.items.isEmpty else {
            return
        }
        let currentIndex = self.nearestIndex(toContentOffset: scrollView.contentOffset.y, feedMetrics: feedMetrics)
        var targetIndex = self.nearestIndex(toContentOffset: targetContentOffset.pointee.y, feedMetrics: feedMetrics)
        if abs(velocity.y) > 0.3 {
            targetIndex = velocity.y > 0.0 ? currentIndex + 1 : currentIndex - 1
        }
        targetIndex = max(0, min(self.items.count - 1, max(currentIndex - 1, min(currentIndex + 1, targetIndex))))
        targetContentOffset.pointee.y = self.clampedContentOffset(feedMetrics.contentOffset(forIndex: targetIndex))
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            self.isUserScrolling = false
            self.presentItemNearestToCenter()
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.isUserScrolling = false
        self.presentItemNearestToCenter()
    }
}
