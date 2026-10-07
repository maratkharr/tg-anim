import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ContextUI
import TelegramUIPreferences
import UniversalMediaPlayer
import ChatControllerInteraction
import PeerInfoPaneNode
import CirclesGridNode

/// Shared Media "Circles" pane: the chat's video messages as a `CirclesGridNode`, loaded from the `.roundVideo`
/// tag history in pages of 50 like the GIF pane. Playback runs through a `.custom` playlist built from the
/// loaded messages, so auto-advance stays within the circles, and the pane hosts the media header panel
/// (pause / rate / close) for that playlist the way the list panes do.
final class PeerInfoCirclesPaneNode: ASDisplayNode, PeerInfoPaneNode {
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let chatLocation: ChatLocation
    private let chatLocationContextHolder: Atomic<ChatLocationContextHolder?>
    private let chatControllerInteraction: ChatControllerInteraction

    weak var parentController: ViewController?

    private let gridNode: CirclesGridNode
    private let headerNode: CirclesMediaHeaderNode
    
    private var currentParams: (size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, navigationHeight: CGFloat, presentationData: PresentationData)?

    private let ready = Promise<Bool>()
    var isReady: Signal<Bool, NoError> {
        return self.ready.get()
    }

    private let listDisposable = MetaDisposable()
    private var numberOfItemsToRequest: Int = 50
    private var currentView: EngineRawMessageHistoryView?
    private var isRequestingView: Bool = false

    private var messages: [EngineRawMessage] = []
    private let messagesPromise = Promise<([EngineRawMessage], Int32, Bool)>(([], 0, false))

    private let statusPromise = Promise<PeerInfoStatusData?>(nil)
    var status: Signal<PeerInfoStatusData?, NoError> {
        return self.statusPromise.get()
    }

    var tabBarOffsetUpdated: ((ContainedViewLayoutTransition) -> Void)?
    var tabBarOffset: CGFloat {
        return 0.0
    }
    var externalDataUpdated: ((ContainedViewLayoutTransition) -> Void)?

    init(context: AccountContext, chatControllerInteraction: ChatControllerInteraction, peerId: EnginePeer.Id, chatLocation: ChatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>) {
        self.context = context
        self.peerId = peerId
        self.chatLocation = chatLocation
        self.chatLocationContextHolder = chatLocationContextHolder
        self.chatControllerInteraction = chatControllerInteraction

        self.headerNode = CirclesMediaHeaderNode(context: context)

        self.gridNode = CirclesGridNode(context: context, openMessage: { message in
            let _ = chatControllerInteraction.openMessage(message, OpenMessageParams(mode: .default))
        }, messageContextAction: { message, node, rect, gesture in
            chatControllerInteraction.openMessageContextMenu(message, false, node, rect, gesture, nil)
        }, toggleMessageSelection: { id, value in
            chatControllerInteraction.toggleMessagesSelection([id], value)
        }, navigateToMessage: { message in
            context.sharedContext.navigateToChat(accountId: context.account.id, peerId: message.id.peerId, messageId: message.id)
        })
        self.gridNode.selectedMessageIds = chatControllerInteraction.selectionState.flatMap { $0.selectedIds }

        super.init()

        self.addSubnode(self.gridNode)
        self.addSubnode(self.headerNode)
        
        self.headerNode.getController = { [weak self] in
            return self?.parentController
        }
        self.headerNode.stateUpdated = { [weak self] transition in
            guard let self, let (size, topInset, sideInset, bottomInset, deviceMetrics, visibleHeight, isScrollingLockedAtTop, expandProgress, navigationHeight, presentationData) = self.currentParams else {
                return
            }
            self.update(size: size, topInset: topInset, sideInset: sideInset, bottomInset: bottomInset, deviceMetrics: deviceMetrics, visibleHeight: visibleHeight, isScrollingLockedAtTop: isScrollingLockedAtTop, expandProgress: expandProgress, navigationHeight: navigationHeight, presentationData: presentationData, synchronous: true, transition: transition)
        }

        self.gridNode.loadMore = { [weak self] in
            self?.loadMoreIfNeeded()
        }

        self.ready.set(self.gridNode.isReady)

        self.statusPromise.set(context.engine.data.subscribe(
            TelegramEngine.EngineData.Item.Messages.MessageCount(peerId: peerId, threadId: chatLocation.threadId, tag: .roundVideo)
        )
        |> map { count -> PeerInfoStatusData? in
            let count: Int = count ?? 0
            if count == 0 {
                return nil
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            return PeerInfoStatusData(text: presentationData.strings.SharedMedia_VideoMessageCount(Int32(count)), isActivity: false, key: .circles)
        })

        self.requestHistory()

    }
    
    deinit {
        self.listDisposable.dispose()
    }

    /// The playlist a message of this pane plays in: the loaded circles, newest first, so the player never
    /// advances into voice messages of the same chat.
    func playlistLocation(forMessageId id: EngineMessage.Id) -> PeerMessagesPlaylistLocation? {
        guard self.messages.contains(where: { $0.id == id }) else {
            return nil
        }
        return .custom(messages: self.messagesPromise.get(), canReorder: false, at: id, loadMore: { [weak self] in
            self?.loadMoreIfNeeded()
        }, hidePanel: false)
    }

    // MARK: - Loading

    private func requestHistory() {
        if self.isRequestingView {
            return
        }
        self.isRequestingView = true
        self.listDisposable.set((self.context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: self.peerId, threadId: self.chatLocation.threadId), index: .upperBound, anchorIndex: .upperBound, count: self.numberOfItemsToRequest, fixedCombinedReadStates: nil, tag: .tag(.roundVideo))
        |> deliverOnMainQueue).startStrict(next: { [weak self] (view, updateType, _) in
            guard let self else {
                return
            }
            self.isRequestingView = false
            self.updateHistory(view: view, updateType: updateType)
        }))
    }

    private func loadMoreIfNeeded() {
        guard let currentView = self.currentView, currentView.earlierId != nil, !self.isRequestingView else {
            return
        }
        self.numberOfItemsToRequest += 50
        self.requestHistory()
    }

    private func updateHistory(view: EngineRawMessageHistoryView, updateType: EngineViewUpdateType) {
        self.currentView = view
        switch updateType {
        case .FillHole:
            self.requestHistory()
        default:
            var messages: [EngineRawMessage] = []
            for entry in view.entries.reversed() {
                messages.append(entry.message)
            }
            self.messages = messages
            self.messagesPromise.set(.single((messages, Int32(messages.count), view.earlierId != nil)))
            self.gridNode.updateMessages(messages)
        }
    }

    // MARK: - PeerInfoPaneNode

    func update(size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, navigationHeight: CGFloat, presentationData: PresentationData, synchronous: Bool, transition: ContainedViewLayoutTransition) {
        self.currentParams = (size, topInset, sideInset, bottomInset, deviceMetrics, visibleHeight, isScrollingLockedAtTop, expandProgress, navigationHeight, presentationData)

        let headerWidth = size.width - sideInset * 2.0
        let topPanelHeight = self.headerNode.update(width: headerWidth, theme: presentationData.theme, strings: presentationData.strings, transition: transition)
        transition.updateFrame(node: self.headerNode, frame: CGRect(origin: CGPoint(x: sideInset, y: topInset), size: CGSize(width: headerWidth, height: topPanelHeight)))
        
        transition.updateFrame(node: self.gridNode, frame: CGRect(origin: CGPoint(), size: size))
        self.gridNode.update(size: size, topInset: topInset + topPanelHeight, sideInset: sideInset, bottomInset: bottomInset, visibleHeight: visibleHeight, isScrollingLockedAtTop: isScrollingLockedAtTop, presentationData: presentationData, synchronous: synchronous, transition: transition)
    }

    func scrollToTop() -> Bool {
        return self.gridNode.scrollToTop()
    }

    func transferVelocity(_ velocity: CGFloat) {
    }

    func cancelPreviewGestures() {
        self.gridNode.cancelPreviewGestures()
    }

    func findLoadedMessage(id: EngineMessage.Id) -> EngineMessage? {
        return self.gridNode.findLoadedMessage(id: id).flatMap(EngineMessage.init)
    }

    func transitionNodeForGallery(messageId: EngineMessage.Id, media: EngineMedia) -> (ASDisplayNode, CGRect, () -> (UIView?, UIView?))? {
        return self.gridNode.transitionNodeForGallery(messageId: messageId, media: media._asMedia())
    }

    func addToTransitionSurface(view: UIView) {
        self.gridNode.addToTransitionSurface(view: view)
    }

    func updateHiddenMedia() {
    }

    func updateSelectedMessages(animated: Bool) {
        self.gridNode.selectedMessageIds = self.chatControllerInteraction.selectionState.flatMap { $0.selectedIds }
        self.gridNode.updateSelectedMessages(animated: animated)
    }

    func ensureMessageIsVisible(id: EngineMessage.Id) {
        self.gridNode.ensureMessageIsVisible(id: id)
    }
}
