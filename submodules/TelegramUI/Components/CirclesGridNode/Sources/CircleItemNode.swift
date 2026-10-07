import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import PhotoResources
import TelegramStringFormatting
import UniversalMediaPlayer
import GridMessageSelectionNode
import TelegramUniversalVideoContent
import InstantVideoRadialStatusNode
import FileMediaResourceStatus
import AppBundle

/// A video message (round video, "circle") shown by `CirclesGridNode`.
final class CircleItem {
    let message: EngineRawMessage
    let file: TelegramMediaFile

    init?(message: EngineRawMessage) {
        var file: TelegramMediaFile?
        for media in message.effectiveMedia {
            if let value = media as? TelegramMediaFile, value.isInstantVideo {
                file = value
                break
            }
        }
        guard let file else {
            return nil
        }
        self.message = message
        self.file = file
    }

    var stableId: UInt32 {
        return self.message.stableId
    }
}

final class CircleItemInteraction {
    let openMessage: (EngineRawMessage) -> Void
    let togglePlayPause: () -> Void
    let openMessageContextActions: (EngineRawMessage, ContextExtractedContentContainingNode, CGRect, ContextGesture?) -> Void
    let toggleSelection: (EngineMessage.Id, Bool) -> Void
    let navigateToMessage: (EngineRawMessage) -> Void

    var selectedMessageIds: Set<EngineMessage.Id>?

    init(
        openMessage: @escaping (EngineRawMessage) -> Void,
        togglePlayPause: @escaping () -> Void,
        openMessageContextActions: @escaping (EngineRawMessage, ContextExtractedContentContainingNode, CGRect, ContextGesture?) -> Void,
        toggleSelection: @escaping (EngineMessage.Id, Bool) -> Void,
        navigateToMessage: @escaping (EngineRawMessage) -> Void
    ) {
        self.openMessage = openMessage
        self.togglePlayPause = togglePlayPause
        self.openMessageContextActions = openMessageContextActions
        self.toggleSelection = toggleSelection
        self.navigateToMessage = navigateToMessage
    }
}

/// One circle of the grid. The node's frame is the circle's bounding square; the chrome (duration, views,
/// time, "go to chat") sits in the square's corners and fades in with the feed progress. While it is the
/// playing item it hosts an embedded `UniversalVideoNode` with the same content id as the chat and the overlay
/// player, so the playing content moves between them instead of starting a second player.
final class CircleItemNode: ASDisplayNode {
    /// Padding around the circle inside the blur wrapper, so a blurred circle keeps a soft edge instead of
    /// being cut by the wrapper's bounds.
    static let blurPadding: CGFloat = 36.0
    private static let goToMessageButtonSize: CGFloat = 44.0

    private let context: AccountContext
    private let interaction: CircleItemInteraction

    private let ambientNode: ASDisplayNode
    private let ambientImageNode: TransformImageNode
    private let containerNode: ContextControllerSourceNode
    private let extractedNode: ContextExtractedContentContainingNode
    private let blurWrapperNode: ASDisplayNode
    private let circleNode: ASDisplayNode
    private let imageNode: TransformImageNode
    private var videoNode: UniversalVideoNode?
    private var statusNode: InstantVideoRadialStatusNode?
    private let durationNode: ImmediateTextNode
    private let viewsIconNode: ASImageNode
    private let infoNode: ImmediateTextNode
    private let goToMessageButton: HighlightableButtonNode
    private var selectionNode: GridMessageSelectionNode?

    private(set) var item: CircleItem?
    private var diameter: CGFloat = 0.0
    private var presentationData: PresentationData?
    private var isPlaying: Bool = false
    private var detachGeneration: Int = 0

    init(context: AccountContext, interaction: CircleItemInteraction) {
        self.context = context
        self.interaction = interaction

        self.containerNode = ContextControllerSourceNode()
        self.extractedNode = ContextExtractedContentContainingNode()

        self.blurWrapperNode = ASDisplayNode()
        self.circleNode = ASDisplayNode()
        self.circleNode.clipsToBounds = true

        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = []

        // A blurred, enlarged copy of the thumbnail glows behind the playing circle (ambient light).
        self.ambientImageNode = TransformImageNode()
        self.ambientImageNode.contentAnimations = []
        self.ambientImageNode.clipsToBounds = true
        self.ambientNode = ASDisplayNode()
        self.ambientNode.isUserInteractionEnabled = false
        self.ambientNode.alpha = 0.0
        if let blurFilter = CALayer.blur() {
            blurFilter.setValue(48.0 as NSNumber, forKey: "inputRadius")
            self.ambientNode.layer.filters = [blurFilter]
        }

        self.durationNode = ImmediateTextNode()
        self.durationNode.displaysAsynchronously = false
        self.durationNode.alpha = 0.0

        self.viewsIconNode = ASImageNode()
        self.viewsIconNode.displaysAsynchronously = false
        self.viewsIconNode.alpha = 0.0

        self.infoNode = ImmediateTextNode()
        self.infoNode.displaysAsynchronously = false
        self.infoNode.alpha = 0.0

        self.goToMessageButton = HighlightableButtonNode()
        self.goToMessageButton.alpha = 0.0
        self.goToMessageButton.isUserInteractionEnabled = false

        super.init()

        self.addSubnode(self.ambientNode)
        self.ambientNode.addSubnode(self.ambientImageNode)
        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.extractedNode)
        self.extractedNode.contentNode.addSubnode(self.blurWrapperNode)
        self.blurWrapperNode.addSubnode(self.circleNode)
        self.circleNode.addSubnode(self.imageNode)
        self.extractedNode.contentNode.addSubnode(self.durationNode)
        self.extractedNode.contentNode.addSubnode(self.viewsIconNode)
        self.extractedNode.contentNode.addSubnode(self.infoNode)
        self.extractedNode.contentNode.addSubnode(self.goToMessageButton)

        self.containerNode.activated = { [weak self] gesture, _ in
            guard let self, let item = self.item else {
                return
            }
            cancelParentGestures(view: self.view)
            self.interaction.openMessageContextActions(item.message, self.extractedNode, self.extractedNode.bounds, gesture)
        }

        self.goToMessageButton.addTarget(self, action: #selector(self.goToMessagePressed), forControlEvents: .touchUpInside)
    }

    override func didLoad() {
        super.didLoad()

        let recognizer = TapLongTapOrDoubleTapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        recognizer.tapActionAtPoint = { _ in
            return .waitForSingleTap
        }
        self.circleNode.view.addGestureRecognizer(recognizer)
    }

    @objc private func tapGesture(_ recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        guard let item = self.item, case .ended = recognizer.state, let (gesture, _) = recognizer.lastRecognizedGestureAndLocation, case .tap = gesture else {
            return
        }
        if let selectedIds = self.interaction.selectedMessageIds {
            self.interaction.toggleSelection(item.message.id, !selectedIds.contains(item.message.id))
        } else if self.isPlaying {
            self.interaction.togglePlayPause()
        } else {
            self.interaction.openMessage(item.message)
        }
    }

    @objc private func goToMessagePressed() {
        guard let item = self.item else {
            return
        }
        self.interaction.navigateToMessage(item.message)
    }

    func cancelPreviewGesture() {
        self.containerNode.cancelGesture()
    }

    /// Binds a message to the node. Thumbnails are requested only when the item changes.
    func update(item: CircleItem, presentationData: PresentationData, synchronousLoad: Bool) {
        let previousItem = self.item
        self.item = item
        self.presentationData = presentationData

        if previousItem?.message.id != item.message.id || previousItem?.file.fileId != item.file.fileId {
            self.imageNode.setSignal(mediaGridMessageVideo(postbox: self.context.account.postbox, userLocation: .peer(item.message.id.peerId), videoReference: .message(message: MessageReference(item.message), media: item.file), synchronousLoad: synchronousLoad, autoFetchFullSizeThumbnail: true), attemptSynchronously: synchronousLoad)
            self.ambientImageNode.setSignal(mediaGridMessageVideo(postbox: self.context.account.postbox, userLocation: .peer(item.message.id.peerId), videoReference: .message(message: MessageReference(item.message), media: item.file), synchronousLoad: false, autoFetchFullSizeThumbnail: true))

            self.detachGeneration += 1
            if let videoNode = self.videoNode {
                self.videoNode = nil
                videoNode.canAttachContent = false
                videoNode.removeFromSupernode()
            }
            self.statusNode?.status = nil
        }

        let durationText = stringForDuration(Int32(item.file.duration ?? 0.0))
        self.durationNode.attributedText = NSAttributedString(string: durationText, font: Font.regular(13.0), textColor: presentationData.theme.list.itemSecondaryTextColor)

        var infoComponents: [String] = []
        var hasViews = false
        for attribute in item.message.attributes {
            if let attribute = attribute as? ViewCountMessageAttribute, attribute.count > 0 {
                infoComponents.append(compactNumericCountString(attribute.count, decimalSeparator: presentationData.dateTimeFormat.decimalSeparator))
                hasViews = true
                break
            }
        }
        infoComponents.append(stringForTime(timestamp: item.message.timestamp, dateTimeFormat: presentationData.dateTimeFormat))
        self.infoNode.attributedText = NSAttributedString(string: infoComponents.joined(separator: "  "), font: Font.regular(13.0), textColor: presentationData.theme.list.itemSecondaryTextColor)
        self.viewsIconNode.isHidden = !hasViews
        if self.viewsIconNode.image == nil || previousItem == nil {
            self.viewsIconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Message/ImpressionCount"), color: presentationData.theme.list.itemSecondaryTextColor)
        }
        if self.goToMessageButton.image(for: .normal) == nil || previousItem == nil {
            self.goToMessageButton.setImage(generateTintedImage(image: UIImage(bundleImageName: "Chat/Message/GoToMessageCircle"), color: .white), for: .normal)
        }

        self.updateSelectionState(animated: false)
    }

    /// Applies the geometry. `progress` is the feed proximity to the viewport center (0 in the grid) and drives
    /// the chrome and the ambient glow; `blurRadius` softens the whole circle, edge included, and `contentAlpha`
    /// dims it (the feed's neighbours are shown at half opacity). `isPlaying` makes
    /// the node own the embedded player: it is created at once, but released only after a short delay, so a
    /// hand-over to the next circle never leaves the content to the overlay mini player in between.
    func updateLayout(diameter: CGFloat, progress: CGFloat, blurRadius: CGFloat, contentAlpha: CGFloat, isPlaying: Bool, isAttached: Bool, transition: ContainedViewLayoutTransition) {
        guard let item = self.item, let presentationData = self.presentationData else {
            return
        }
        self.diameter = diameter
        self.isPlaying = isPlaying

        let bounds = CGRect(origin: CGPoint(), size: CGSize(width: diameter, height: diameter))
        let padding = CircleItemNode.blurPadding
        let wrapperFrame = bounds.insetBy(dx: -padding, dy: -padding)

        transition.updateFrame(node: self.containerNode, frame: bounds)
        transition.updateFrame(node: self.extractedNode, frame: bounds)
        self.extractedNode.contentRect = bounds
        transition.updateFrame(node: self.extractedNode.contentNode, frame: bounds)

        transition.updateFrame(node: self.blurWrapperNode, frame: wrapperFrame)
        transition.updateFrame(node: self.circleNode, frame: CGRect(origin: CGPoint(x: padding, y: padding), size: bounds.size))
        transition.updateCornerRadius(node: self.circleNode, cornerRadius: diameter * 0.5)

        transition.updateFrame(node: self.imageNode, frame: bounds)
        let imageSize = (item.file.dimensions?.cgSize ?? CGSize(width: 240.0, height: 240.0)).aspectFilled(bounds.size)
        self.imageNode.asyncLayout()(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: bounds.size, intrinsicInsets: UIEdgeInsets(), emptyColor: presentationData.theme.list.mediaPlaceholderColor))()

        // The blur sits on the padded wrapper, which does not clip, so the circle's edge dissolves as well.
        if blurRadius > 0.5 {
            if let blurFilter = self.blurWrapperNode.layer.filters?.first as? NSObject {
                blurFilter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
            } else if let blurFilter = CALayer.blur() {
                blurFilter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
                self.blurWrapperNode.layer.filters = [blurFilter]
            }
        } else if self.blurWrapperNode.layer.filters != nil {
            self.blurWrapperNode.layer.filters = nil
        }
        transition.updateAlpha(node: self.blurWrapperNode, alpha: contentAlpha)

        let ambientInset = -diameter * 0.12
        let ambientFrame = bounds.insetBy(dx: ambientInset, dy: ambientInset)
        transition.updateFrame(node: self.ambientNode, frame: ambientFrame)
        transition.updateFrame(node: self.ambientImageNode, frame: CGRect(origin: CGPoint(), size: ambientFrame.size))
        transition.updateCornerRadius(node: self.ambientImageNode, cornerRadius: ambientFrame.width * 0.5)
        self.ambientImageNode.asyncLayout()(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize.aspectFilled(ambientFrame.size), boundingSize: ambientFrame.size, intrinsicInsets: UIEdgeInsets(), emptyColor: .clear))()
        transition.updateAlpha(node: self.ambientNode, alpha: 0.3 * progress * progress)

        if isPlaying {
            self.detachGeneration += 1
            if self.videoNode == nil {
                let mediaManager = self.context.sharedContext.mediaManager
                let interaction = self.interaction
                let videoNode = UniversalVideoNode(context: self.context, postbox: self.context.account.postbox, audioSession: mediaManager.audioSession, manager: mediaManager.universalVideoManager, decoration: ChatBubbleInstantVideoDecoration(inset: 0.0, backgroundImage: nil, tapped: {
                    interaction.togglePlayPause()
                }), content: NativeVideoContent(id: .message(item.message.stableId, item.file.fileId), userLocation: .peer(item.message.id.peerId), fileReference: .message(message: MessageReference(item.message), media: item.file), streamVideo: isMediaStreamable(message: EngineMessage(item.message), media: item.file) ? .conservative : .none, enableSound: false, fetchAutomatically: false, isAudioVideoMessage: true, storeAfterDownload: nil), priority: .embedded, autoplay: false)
                videoNode.isUserInteractionEnabled = false
                self.videoNode = videoNode
                self.circleNode.addSubnode(videoNode)
            }
            if self.statusNode == nil {
                let statusNode = InstantVideoRadialStatusNode(color: UIColor(white: 1.0, alpha: 0.6), hasSeek: true)
                statusNode.isUserInteractionEnabled = false
                let file = item.file
                statusNode.status = messageFileMediaPlaybackStatus(context: self.context, file: file, message: EngineMessage(item.message), isRecentActions: false, isGlobalSearch: true, isDownloadList: false, isSavedMusic: false)
                let context = self.context
                statusNode.seekTo = { position, _ in
                    guard let duration = file.duration else {
                        return
                    }
                    context.sharedContext.mediaManager.playlistControl(.seek(position * duration), type: .voice)
                }
                self.statusNode = statusNode
                self.extractedNode.contentNode.addSubnode(statusNode)
                if transition.isAnimated {
                    statusNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                }
            }
        } else if self.videoNode != nil || self.statusNode != nil {
            if let statusNode = self.statusNode {
                self.statusNode = nil
                statusNode.status = nil
                if transition.isAnimated {
                    statusNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { [weak statusNode] _ in
                        statusNode?.removeFromSupernode()
                    })
                } else {
                    statusNode.removeFromSupernode()
                }
            }
            // Keep the player attached while the hand-over to the next circle happens; release it afterwards.
            self.detachGeneration += 1
            let generation = self.detachGeneration
            Queue.mainQueue().after(0.6) { [weak self] in
                guard let self, self.detachGeneration == generation, !self.isPlaying, let videoNode = self.videoNode else {
                    return
                }
                self.videoNode = nil
                videoNode.canAttachContent = false
                videoNode.removeFromSupernode()
            }
        }

        if let videoNode = self.videoNode {
            // Slightly larger than the circle: the decoration keeps a hairline inset of thumbnail around the
            // video otherwise, which read as a stray outline on the first frame.
            let videoFrame = bounds.insetBy(dx: -2.0, dy: -2.0)
            transition.updateFrame(node: videoNode, frame: videoFrame)
            videoNode.updateLayout(size: videoFrame.size, transition: transition)
            videoNode.canAttachContent = isAttached
        }
        if let statusNode = self.statusNode {
            transition.updateFrame(node: statusNode, frame: bounds.insetBy(dx: 1.5, dy: 1.5))
        }

        // Chrome in the corners of the bounding square, outside the circle; visible only near the center.
        let chromeAlpha: CGFloat = progress * progress
        let durationSize = self.durationNode.updateLayout(CGSize(width: diameter, height: 20.0))
        transition.updateFrame(node: self.durationNode, frame: CGRect(origin: CGPoint(x: 2.0, y: diameter - durationSize.height - 2.0), size: durationSize))
        transition.updateAlpha(node: self.durationNode, alpha: chromeAlpha)

        let infoSize = self.infoNode.updateLayout(CGSize(width: diameter, height: 20.0))
        let infoFrame = CGRect(origin: CGPoint(x: diameter - infoSize.width - 2.0, y: diameter - infoSize.height - 2.0), size: infoSize)
        transition.updateFrame(node: self.infoNode, frame: infoFrame)
        transition.updateAlpha(node: self.infoNode, alpha: chromeAlpha)
        if let icon = self.viewsIconNode.image {
            let iconSize = icon.size
            transition.updateFrame(node: self.viewsIconNode, frame: CGRect(origin: CGPoint(x: infoFrame.minX - iconSize.width - 4.0, y: infoFrame.midY - iconSize.height * 0.5 + 1.0), size: iconSize))
        }
        transition.updateAlpha(node: self.viewsIconNode, alpha: chromeAlpha)

        // 30pt glyph centered in a 44pt tap target, no background.
        let buttonSize = CircleItemNode.goToMessageButtonSize
        transition.updateFrame(node: self.goToMessageButton, frame: CGRect(origin: CGPoint(x: diameter - buttonSize + 4.0, y: diameter - buttonSize - 26.0), size: CGSize(width: buttonSize, height: buttonSize)))
        transition.updateAlpha(node: self.goToMessageButton, alpha: chromeAlpha)
        self.goToMessageButton.isUserInteractionEnabled = progress > 0.5

        self.selectionNode?.frame = bounds
        self.containerNode.isGestureEnabled = self.interaction.selectedMessageIds == nil
    }

    func updateSelectionState(animated: Bool) {
        guard let item = self.item, let presentationData = self.presentationData else {
            return
        }
        self.containerNode.isGestureEnabled = self.interaction.selectedMessageIds == nil

        if let selectedIds = self.interaction.selectedMessageIds {
            let selected = selectedIds.contains(item.message.id)
            if let selectionNode = self.selectionNode {
                selectionNode.updateSelected(selected, animated: animated)
            } else {
                let selectionNode = GridMessageSelectionNode(theme: presentationData.theme, toggle: { [weak self] value in
                    guard let self, let item = self.item else {
                        return
                    }
                    self.interaction.toggleSelection(item.message.id, value)
                })
                selectionNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: self.diameter, height: self.diameter))
                self.extractedNode.contentNode.addSubnode(selectionNode)
                self.selectionNode = selectionNode
                selectionNode.updateSelected(selected, animated: false)
                if animated {
                    selectionNode.animateIn()
                }
            }
        } else if let selectionNode = self.selectionNode {
            self.selectionNode = nil
            if animated {
                selectionNode.animateOut { [weak selectionNode] in
                    selectionNode?.removeFromSupernode()
                }
            } else {
                selectionNode.removeFromSupernode()
            }
        }
    }

    func transitionNode() -> (ASDisplayNode, CGRect, () -> (UIView?, UIView?))? {
        let circleNode = self.circleNode
        return (circleNode, circleNode.bounds, { [weak circleNode] in
            return (circleNode?.view.snapshotContentTree(unhide: true), nil)
        })
    }
}

private func stringForTime(timestamp: Int32, dateTimeFormat: PresentationDateTimeFormat) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    if case .military = dateTimeFormat.timeFormat {
        formatter.dateFormat = "HH:mm"
    }
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}
