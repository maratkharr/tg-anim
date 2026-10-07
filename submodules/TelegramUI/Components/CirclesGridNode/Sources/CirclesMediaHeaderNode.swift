import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ComponentFlow
import ComponentDisplayAdapters
import GlobalControlPanelsContext
import MediaPlaybackHeaderPanelComponent
import HeaderPanelContainerComponent

/// The "island" media playback header (title, date, pause, rate, close) that the chat shows while a voice or
/// video message plays, hosted by a circles pane. It follows `GlobalControlPanelsContext` and shows only the
/// `.custom` voice playlists the circles start, so other playback (music, a chat's own voice playlist) does not
/// surface here.
public final class CirclesMediaHeaderNode: ASDisplayNode {
    private let context: AccountContext
    private let panelsContext: GlobalControlPanelsContext
    private var stateDisposable: Disposable?

    private var mediaPlayback: GlobalControlPanelsContext.MediaPlayback?
    private var panelView: ComponentView<Empty>?

    /// The view controller used for tooltips and pushes performed by the panel; it must have a navigation controller.
    public var getController: () -> ViewController? = { nil }
    /// Called when the panel appears or disappears, so the host can relayout with the returned height.
    public var stateUpdated: ((ContainedViewLayoutTransition) -> Void)?

    public static let verticalInset: CGFloat = 8.0

    public init(context: AccountContext) {
        self.context = context
        self.panelsContext = GlobalControlPanelsContext(context: context, mediaPlayback: true, liveLocationMode: nil, groupCalls: nil, chatListNotices: false)

        super.init()

        self.stateDisposable = (self.panelsContext.state
        |> deliverOnMainQueue).startStrict(next: { [weak self] state in
            guard let self else {
                return
            }
            var mediaPlayback: GlobalControlPanelsContext.MediaPlayback?
            if let value = state.mediaPlayback, case .voice = value.kind, let playlistLocation = value.playlistLocation as? PeerMessagesPlaylistLocation, case .custom = playlistLocation.playlistId {
                mediaPlayback = value
            }
            if (self.mediaPlayback == nil) != (mediaPlayback == nil) || self.mediaPlayback?.version != mediaPlayback?.version {
                self.mediaPlayback = mediaPlayback
                self.stateUpdated?(.animated(duration: 0.4, curve: .spring))
            }
        })
    }

    deinit {
        self.stateDisposable?.dispose()
    }

    public var isDisplayingPanel: Bool {
        return self.mediaPlayback != nil
    }

    /// Lays the panel out at the top of the node and returns the height it occupies, including its vertical
    /// insets; 0 when nothing of interest is playing.
    public func update(width: CGFloat, theme: PresentationTheme, strings: PresentationStrings, transition: ContainedViewLayoutTransition) -> CGFloat {
        guard let mediaPlayback = self.mediaPlayback else {
            if let panelView = self.panelView {
                self.panelView = nil
                if let view = panelView.view {
                    transition.updateAlpha(layer: view.layer, alpha: 0.0, completion: { [weak view] _ in
                        view?.removeFromSuperview()
                    })
                    transition.updateTransformScale(layer: view.layer, scale: 0.9)
                }
            }
            return 0.0
        }

        let panelView: ComponentView<Empty>
        var panelTransition = ComponentTransition(transition)
        if let current = self.panelView {
            panelView = current
        } else {
            panelView = ComponentView()
            self.panelView = panelView
            panelTransition = panelTransition.withAnimation(.none)
        }

        let getController = self.getController
        let size = panelView.update(
            transition: panelTransition,
            component: AnyComponent(HeaderPanelContainerComponent(
                theme: theme,
                tabs: nil,
                panels: [HeaderPanelContainerComponent.Panel(key: "media", orderIndex: 0, component: AnyComponent(MediaPlaybackHeaderPanelComponent(
                    context: self.context,
                    theme: theme,
                    strings: strings,
                    data: mediaPlayback,
                    controller: {
                        return getController()
                    }
                )))]
            )),
            environment: {},
            containerSize: CGSize(width: width, height: 1000.0)
        )
        if let view = panelView.view {
            let frame = CGRect(origin: CGPoint(x: 0.0, y: CirclesMediaHeaderNode.verticalInset), size: size)
            if view.superview == nil {
                self.view.addSubview(view)
                view.frame = frame
                if transition.isAnimated {
                    view.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                    view.layer.animateScale(from: 0.9, to: 1.0, duration: 0.4, timingFunction: ContainedViewLayoutTransitionCurve.spring.timingFunction)
                }
            } else {
                transition.updateFrame(view: view, frame: frame)
            }
        }
        return size.height + CirclesMediaHeaderNode.verticalInset * 2.0
    }
}
