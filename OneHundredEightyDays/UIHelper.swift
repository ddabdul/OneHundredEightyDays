//
//  UIhelpers.swift
//  OneHundredEightyDays
//

import UIKit
import SwiftUI

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct HidingAssistantTextField: UIViewRepresentable {
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onReturn: (() -> Void)?

        init(text: Binding<String>, onReturn: (() -> Void)?) {
            self.text = text
            self.onReturn = onReturn
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()   // end first responder cleanly
            onReturn?()                        // advance focus / custom action
            return true
        }
    }

    @Binding var text: String
    var placeholder: String = ""
    var contentType: UITextContentType?
    var capitalization: UITextAutocapitalizationType = .sentences
    var keyboard: UIKeyboardType = .default
    var returnKey: UIReturnKeyType = .done
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var onReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator { .init(text: $text, onReturn: onReturn) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.delegate = context.coordinator
        tf.borderStyle = .roundedRect
        tf.placeholder = placeholder
        tf.text = text
        tf.textContentType = contentType
        tf.autocapitalizationType = capitalization
        tf.autocorrectionType = .no
        tf.keyboardType = keyboard
        tf.returnKeyType = returnKey
        tf.font = font

        // Hide the QuickType / input assistant bar
        let item = tf.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []

        tf.accessibilityLabel = placeholder
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.textContentType = contentType
        uiView.autocapitalizationType = capitalization
        uiView.keyboardType = keyboard
        uiView.returnKeyType = returnKey

        // Re-hide if UIKit reconfigures the assistant
        let item = uiView.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
    }
}
