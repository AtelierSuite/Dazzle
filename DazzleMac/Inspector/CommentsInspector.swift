import AppKit
import DazzleEngine

/// The Comments tab: the slide's threads, read, replied to, resolved and
/// deleted, and a new one started.
extension InspectorViewController {
    /// Who comments are written as, remembered between sessions.
    static var authorName: String {
        get { UserDefaults.standard.string(forKey: "commentAuthorName")?.nilIfEmpty ?? NSFullUserName() }
        set { UserDefaults.standard.set(newValue, forKey: "commentAuthorName") }
    }

    func buildComments() {
        guard let slide = deck.selectedSlide else { return }
        form.row(String(localized: "Comments.CommentAs"), form.text(placeholder: String(localized: "Comments.YourName"), get: {
            Self.authorName
        }, set: { name in
            Self.authorName = name.trimmed
        }))
        form.note(String(localized: "Comments.YourName.Footer"))

        let draft = NSTextField()
        draft.placeholderString = String(localized: "Comments.Placeholder")
        draft.setAccessibilityIdentifier("newComment")
        let add = form.button(String(localized: "Comments.Add"), symbol: "plus.bubble") { [unowned self] in
            let text = draft.stringValue
            guard !text.trimmed.isEmpty else { return }
            edit { state.addComment(text, author: Self.authorName, in: &$0) }
        }
        form.section(String(localized: "Comments.New"))
        form.add(draft, fill: true)
        form.add(add)

        guard !slide.comments.isEmpty else {
            form.section(String(localized: "Panel.Comments.Title"))
            form.note(String(localized: "Comments.Empty"))
            return
        }
        for thread in slide.comments {
            buildThread(thread)
        }
    }

    private func buildThread(_ thread: SlideComment) {
        form.section(thread.author.nilIfEmpty ?? String(localized: "Comments.Unknown"))
        form.add(commentBody(thread), fill: true)
        for reply in thread.replies {
            let body = commentBody(reply, showsAuthor: true)
            let delete = form.iconButton("trash", label: String(localized: "Comments.Delete")) { [unowned self] in
                edit { state.deleteComment(thread.id, replyID: reply.id, in: &$0) }
            }
            let row = NSStackView(views: [body, delete])
            row.alignment = .top
            row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
            body.setContentHuggingPriority(.defaultLow, for: .horizontal)
            form.add(row, fill: true)
        }
        let reply = NSTextField()
        reply.placeholderString = String(localized: "Comments.Reply")
        let send = form.button(String(localized: "Comments.Send")) { [unowned self] in
            let text = reply.stringValue
            guard !text.trimmed.isEmpty else { return }
            edit { state.reply(to: thread.id, with: text, author: Self.authorName, in: &$0) }
        }
        let replyRow = NSStackView(views: [reply, send])
        reply.setContentHuggingPriority(.defaultLow, for: .horizontal)
        form.add(replyRow, fill: true)
        let resolve = form.button(String(localized: thread.isResolved ? "Comments.Reopen" : "Comments.Resolve"),
                                  symbol: thread.isResolved ? "arrow.uturn.backward" : "checkmark.circle") { [unowned self] in
            edit { state.setCommentResolved(thread.id, !thread.isResolved, in: &$0) }
        }
        let delete = form.button(String(localized: "Comments.DeleteThread"), symbol: "trash") { [unowned self] in
            edit { state.deleteComment(thread.id, in: &$0) }
        }
        let actions = NSStackView(views: [resolve, delete])
        actions.spacing = 6
        form.add(actions)
    }

    private func commentBody(_ comment: SlideComment, showsAuthor: Bool = false) -> NSView {
        var heading = showsAuthor ? (comment.author.nilIfEmpty ?? String(localized: "Comments.Unknown")) : ""
        if let date = comment.date {
            let when = date.formatted(date: .abbreviated, time: .shortened)
            heading = heading.isEmpty ? when : heading + " · " + when
        }
        if comment.isResolved { heading += (heading.isEmpty ? "" : " · ") + String(localized: "Comments.Resolved") }
        let header = NSTextField(labelWithString: heading)
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        header.textColor = .secondaryLabelColor
        let text = NSTextField(wrappingLabelWithString: comment.text)
        text.isSelectable = true
        let stack = NSStackView(views: [header, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }
}
