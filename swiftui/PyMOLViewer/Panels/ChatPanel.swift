// ChatPanel.swift — AI chat interface for PyMOL
// Replaces modules/pymol/ai_chat_ui.py with pure SwiftUI.

import SwiftUI

// MARK: - Data Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date

    enum Role { case user, assistant, error }
}

// MARK: - View Model

class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isTyping = false

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed, timestamp: Date())
        messages.append(userMessage)

        isTyping = true

        // Stub: simulate AI response after a short delay.
        // The real backend (ai_chat.py) will be wired in later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let response = ChatMessage(
                role: .assistant,
                content: "This is a placeholder response. The AI backend will be connected in a future update.\n\n```python\nfetch 1ubq\ncartoon automatic\ncolor cyan\n```",
                timestamp: Date()
            )
            self.messages.append(response)
            self.isTyping = false
        }
    }

    func clearConversation() {
        messages.removeAll()
        isTyping = false
    }
}

// MARK: - Chat Panel

struct ChatPanel: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    private let bgColor = Color(red: 0.149, green: 0.149, blue: 0.161)           // #262629
    private let inputBgColor = Color(red: 0.2, green: 0.2, blue: 0.2)            // #333333
    private let accentBlue = Color(red: 0.29, green: 0.565, blue: 0.851)         // #4A90D9

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            Divider()
                .background(Color.gray.opacity(0.3))

            // Message list
            messageList

            // Typing indicator
            if viewModel.isTyping {
                typingIndicator
            }

            Divider()
                .background(Color.gray.opacity(0.3))

            // Input bar
            inputBar
        }
        .background(bgColor)
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundColor(accentBlue)
                .font(.system(size: 12))

            Text("AI Chat")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))

            Spacer()

            Button(action: { viewModel.clearConversation() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.messages.isEmpty {
                        emptyStateView
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(bgColor)
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(accentBlue.opacity(0.5))

            Text("Ask PyMOL AI for help with\nvisualization, analysis, or scripting")
                .font(.system(size: 12))
                .foregroundColor(Color.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            TypingDots()
            Text("Thinking...")
                .font(.system(size: 11))
                .foregroundColor(Color.gray)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(bgColor)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask PyMOL AI...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                #if os(macOS)
                .foregroundColor(Color(nsColor: .white))
                #else
                .foregroundColor(.white)
                #endif
                .focused($isInputFocused)
                .onSubmit { sendCurrentMessage() }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(inputBgColor)
                )

            // Send button
            Button(action: sendCurrentMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? accentBlue.opacity(0.4)
                                  : accentBlue)
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || viewModel.isTyping)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(bgColor)
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        let text = inputText
        inputText = ""
        viewModel.sendMessage(text)
    }
}

// MARK: - Message Bubble View

private struct MessageBubbleView: View {
    let message: ChatMessage

    private let userBubbleColor = Color(red: 0.29, green: 0.565, blue: 0.851)  // #4A90D9
    private let assistantTextColor = Color(red: 0.898, green: 0.898, blue: 0.898) // #E5E5E5
    private let errorTextColor = Color(red: 0.878, green: 0.318, blue: 0.318)    // #E05252

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantView
        case .error:
            errorView
        }
    }

    // MARK: - User Bubble (right-aligned, blue)

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)

            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(userBubbleColor)
                )
        }
    }

    // MARK: - Assistant View (left-aligned, no bubble, markdown-ish)

    private var assistantView: some View {
        HStack {
            FormattedTextView(text: message.content, textColor: assistantTextColor)
                .textSelection(.enabled)

            Spacer(minLength: 40)
        }
    }

    // MARK: - Error View

    private var errorView: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(errorTextColor)

                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(errorTextColor)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 40)
        }
    }
}

// MARK: - Formatted Text View (code block support)

/// Renders text with basic markdown-style code blocks.
/// Inline text uses the system font; fenced code blocks (``` ... ```) use monospace
/// on a slightly lighter background.
private struct FormattedTextView: View {
    let text: String
    let textColor: Color

    private let codeBgColor = Color(red: 0.17, green: 0.17, blue: 0.19)    // slightly lighter than panel bg
    private let codeTextColor = Color(red: 0.8, green: 0.9, blue: 0.8)     // light green tint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let content):
                    Text(content)
                        .font(.system(size: 13))
                        .foregroundColor(textColor)

                case .codeBlock(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(codeTextColor)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(codeBgColor)
                        )
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Parse the text into alternating plain-text and code-block segments.
    private var segments: [TextSegment] {
        var result: [TextSegment] = []
        let parts = text.components(separatedBy: "```")

        for (index, part) in parts.enumerated() {
            let content = index.isMultiple(of: 2) ? part : stripLanguageTag(part)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if index.isMultiple(of: 2) {
                result.append(.text(trimmed))
            } else {
                result.append(.codeBlock(trimmed))
            }
        }

        return result
    }

    /// Remove an optional language identifier from the first line of a code block
    /// (e.g., "python\nfetch 1ubq" becomes "fetch 1ubq").
    private func stripLanguageTag(_ code: String) -> String {
        let lines = code.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return code }

        let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
        let knownLangs: Set<String> = [
            "python", "py", "pymol", "bash", "sh", "json", "swift", "cpp", "c",
            "javascript", "js", "text", "plain",
        ]
        if knownLangs.contains(firstLine.lowercased()) {
            return String(lines[1])
        }
        return code
    }
}

private enum TextSegment {
    case text(String)
    case codeBlock(String)
}

// MARK: - Typing Dots Animation

private struct TypingDots: View {
    @State private var dotPhase = 0

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(for: index))
            }
        }
        .onReceive(timer) { _ in
            dotPhase = (dotPhase + 1) % 4
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        if index == dotPhase % 3 { return 1.0 }
        return 0.3
    }
}

// MARK: - Preview

struct ChatPanel_Previews: PreviewProvider {
    static var previews: some View {
        ChatPanel()
            .frame(width: 300, height: 500)
            .preferredColorScheme(.dark)
    }
}
