import CoreGraphics

/// How a list/detail surface lays out its two columns for the current width.
nonisolated enum PaneArrangement: Equatable, Sendable {
    /// One column; a selected detail is pushed onto the list's stack.
    case stack
    /// Two side-by-side columns: list and detail.
    case split
    /// Detail fills the width while a modal or covering screen holds it.
    case detailOnly

    static func preferred(for widthClass: WidthClass) -> PaneArrangement {
        widthClass == .wide ? .split : .stack
    }

    /// The arrangement the surface moves to next. A held detail keeps the surface
    /// on its current arrangement instead of unfolding under the covering screen.
    static func next(
        from current: PaneArrangement,
        widthClass: WidthClass,
        hasDetail: Bool,
        isDetailHeld: Bool
    ) -> PaneArrangement {
        let target = preferred(for: widthClass)
        guard hasDetail else { return target }
        switch target {
        case .split:
            return current == .stack && isDetailHeld ? .stack : .split
        case .stack, .detailOnly:
            return isDetailHeld && current != .stack ? .detailOnly : .stack
        }
    }

    /// Whether moving between two arrangements re-parents the detail view hierarchy,
    /// which re-runs the detail's appear and disappear lifecycle unless it is handed over.
    static func reparentsDetail(from previous: PaneArrangement, to next: PaneArrangement) -> Bool {
        switch (previous, next) {
        case (.stack, .split), (.stack, .detailOnly), (.split, .stack), (.detailOnly, .stack):
            return true
        case (.stack, .stack), (.split, .split), (.split, .detailOnly), (.detailOnly, .split), (.detailOnly, .detailOnly):
            return false
        }
    }
}

/// The inputs that decide whether the detail is held on screen.
nonisolated struct PaneHoldState: Equatable, Sendable {
    var modalHoldCount: Int
    var isRootCovered: Bool
    var isHostVisible: Bool

    var isDetailHeld: Bool {
        modalHoldCount > 0 || (isRootCovered && isHostVisible)
    }
}

nonisolated struct PaneColumnFrames: Equatable, Sendable {
    /// Width of the list column, including any leading safe-area inset.
    let listWidth: CGFloat
    /// Width the list content lays out in, excluding the leading inset.
    let listContentWidth: CGFloat
    let detailLeading: CGFloat
    /// Width of the detail column, including its trailing inset.
    let detailWidth: CGFloat
    /// Width the detail content lays out in, excluding the trailing inset.
    let detailContentWidth: CGFloat
}

nonisolated enum PaneMetrics {
    static let dividerWidth: CGFloat = 1

    /// The list column is 40% of the usable width, clamped to 340...420 points.
    static func listColumnWidth(forUsableWidth usableWidth: CGFloat) -> CGFloat {
        min(max(usableWidth * 0.4, 340), 420)
    }

    static func frames(
        for arrangement: PaneArrangement,
        containerWidth: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> PaneColumnFrames {
        let usableWidth = max(containerWidth - leadingInset - trailingInset, 0)
        switch arrangement {
        case .stack:
            return PaneColumnFrames(
                listWidth: containerWidth,
                listContentWidth: usableWidth,
                detailLeading: 0,
                detailWidth: 0,
                detailContentWidth: 0
            )
        case .split, .detailOnly:
            let listContentWidth = listColumnWidth(forUsableWidth: usableWidth)
            let listWidth = leadingInset + listContentWidth
            let detailLeading: CGFloat
            let detailWidth: CGFloat
            let detailContentWidth: CGFloat
            if arrangement == .split {
                detailLeading = listWidth + dividerWidth
                detailWidth = max(containerWidth - detailLeading, 0)
                detailContentWidth = max(detailWidth - trailingInset, 0)
            } else {
                detailLeading = 0
                detailWidth = containerWidth
                detailContentWidth = usableWidth
            }
            return PaneColumnFrames(
                listWidth: listWidth,
                listContentWidth: listContentWidth,
                detailLeading: detailLeading,
                detailWidth: detailWidth,
                detailContentWidth: detailContentWidth
            )
        }
    }
}

nonisolated enum PaneStackLinkRule {
    /// Popping the stack-mode detail clears the selection, so returning to the list
    /// does not re-push the old detail. Only the stack arrangement pushes details.
    static func clearsSelection(whenSetActive isActive: Bool, arrangement: PaneArrangement) -> Bool {
        !isActive && arrangement == .stack
    }
}
