import SwiftUI
import UIKit

/// A `UITextView` for the editor. SwiftUI's `TextEditor` hides the cursor,
/// and the checklist needs it: the toolbar button, tapping a marker, and the
/// Return key all act on the line under the cursor.
///
/// The first line is drawn semibold, the rest regular with the spec's line
/// height. That styling is applied to the storage after every change, so
/// the text itself stays a plain `String`.
struct ChecklistTextView: UIViewRepresentable {
    enum Command: Equatable {
        /// The toolbar's checklist button.
        case toggleItem
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var command: Command?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .black
        view.textColor = .white
        view.tintColor = .white
        view.font = Style.body
        view.keyboardAppearance = .dark
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 40, right: 0)
        view.autocorrectionType = .default
        view.smartDashesType = .no
        view.smartQuotesType = .default
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.text = text
        view.typingAttributes = Style.attributes(semibold: text.isEmpty || !text.contains("\n"))
        context.coordinator.restyle(view)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if view.text != text {
            // A change from outside (sync, or the delete blanking the note).
            let selection = view.selectedRange
            view.text = text
            coordinator.restyle(view)
            let end = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, end), length: 0)
        }
        if let command {
            DispatchQueue.main.async {
                coordinator.run(command, on: view)
                self.command = nil
            }
        }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async {
                let end = (view.text as NSString).length
                view.selectedRange = NSRange(location: end, length: 0)
                view.becomeFirstResponder()
            }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Style

    enum Style {
        static let body = UIFont.systemFont(ofSize: Theme.Font.editorSize, weight: .regular)
        static let title = UIFont.systemFont(ofSize: Theme.Font.editorSize, weight: .semibold)

        static var paragraph: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            let target = Theme.Font.editorSize * Theme.Font.editorLineHeight
            style.lineSpacing = max(0, target - body.lineHeight)
            return style
        }

        static func attributes(semibold: Bool) -> [NSAttributedString.Key: Any] {
            [
                .font: semibold ? title : body,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ChecklistTextView
        weak var textView: UITextView?

        init(_ parent: ChecklistTextView) {
            self.parent = parent
        }

        // MARK: Editing

        func textViewDidChange(_ view: UITextView) {
            restyle(view)
            parent.text = view.text
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            let firstLine = Checklist.lineRange(in: view.text, at: 0)
            let onFirstLine = view.selectedRange.location <= firstLine.length
            view.typingAttributes = Style.attributes(semibold: onFirstLine)
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n",
                  let edit = Checklist.handleReturn(in: view.text, selection: range) else {
                return true
            }
            apply(edit, to: view)
            return false
        }

        // MARK: Commands

        func run(_ command: Command, on view: UITextView) {
            switch command {
            case .toggleItem:
                let cursor = view.selectedRange.location
                apply(Checklist.toggleItem(in: view.text, at: cursor), to: view)
                if !view.isFirstResponder { view.becomeFirstResponder() }
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            guard Checklist.isOnMarker(in: view.text, at: offset) else { return }
            let edit = Checklist.toggleDone(in: view.text, at: offset)
            // The text view also handles this tap and moves the cursor; wait
            // for it, then put the cursor after the marker on that line.
            let line = Checklist.lineRange(in: view.text, at: offset)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(Checklist.Edit(text: edit.text,
                                          cursor: line.location + Checklist.markerLength), to: view)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Helpers

        private func apply(_ edit: Checklist.Edit, to view: UITextView) {
            guard view.text != edit.text else {
                view.selectedRange = NSRange(location: edit.cursor, length: 0)
                return
            }
            view.text = edit.text
            restyle(view)
            let end = (edit.text as NSString).length
            view.selectedRange = NSRange(location: min(edit.cursor, end), length: 0)
            parent.text = edit.text
        }

        /// First line semibold, the rest regular, everything white with the
        /// spec's line height. Edits the storage directly, which does not
        /// call back into `textViewDidChange`.
        func restyle(_ view: UITextView) {
            let storage = view.textStorage
            let length = storage.length
            guard length > 0 else {
                view.typingAttributes = Style.attributes(semibold: true)
                return
            }
            let firstLine = Checklist.lineRange(in: view.text, at: 0)
            let selection = view.selectedRange
            storage.beginEditing()
            storage.setAttributes(Style.attributes(semibold: false),
                                  range: NSRange(location: 0, length: length))
            if firstLine.length > 0 {
                storage.addAttributes(Style.attributes(semibold: true), range: firstLine)
            }
            storage.endEditing()
            view.selectedRange = selection
            view.typingAttributes = Style.attributes(semibold: selection.location <= firstLine.length)
        }
    }
}

/// Hiding the back button turns off the swipe-from-the-left-edge pop. The
/// editor hides the whole bar and draws its own, so put the gesture back.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldBegin _: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
