import SwiftUI

private let bubbleYellow = Color(red: 1, green: 1, blue: 0.86)

struct BuddyView: View {
    @ObservedObject var state: BuddyState
    let rig: Rig
    let actions: BuddyActions

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            if state.showInput {
                AskBox(state: state, submit: actions.submit, cancel: actions.cancelInput)
                    .hitRegion("input")
            } else if let text = state.bubbleText {
                SpeechBubble(text: text, thinking: state.thinking)
                    .hitRegion("bubble")
                    .onTapGesture(perform: actions.dismissBubble)
            }
            GorillaView(rig: rig)
                .frame(width: BuddyLayout.gorillaSize.width, height: BuddyLayout.gorillaSize.height)
                .contentShape(Rectangle())
                .hitRegion("gorilla")
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { _ in actions.dragChanged() }
                        .onEnded { _ in actions.dragEnded() }
                )
                .onTapGesture(perform: actions.tapped)
                .contextMenu {
                    Button("Chat with Bonzai…", action: actions.tapped)
                    Button("Tell Me a Joke", action: actions.joke)
                    Button("Fun Fact", action: actions.fact)
                    Button("Shush", action: actions.hush)
                    Divider()
                    Button("Settings…", action: actions.settings)
                    Button("Quit Bonzai Buddy", action: actions.quit)
                }
        }
        .frame(width: BuddyLayout.windowSize.width, height: BuddyLayout.windowSize.height)
        .onPreferenceChange(HitRectKey.self) { rects in
            MainActor.assumeIsolated { state.hitRects = rects }
        }
    }
}

/// Classic yellow Microsoft-Agent-style speech balloon.
struct SpeechBubble: View {
    let text: String
    let thinking: Bool

    var body: some View {
        let shown = thinking && text.isEmpty ? "Hmmm… let me think…" : text
        ViewThatFits(in: .vertical) {
            label(shown).fixedSize(horizontal: false, vertical: true)
            ScrollView { label(shown) }
                .defaultScrollAnchor(.bottom)
                .frame(height: 210)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 9 + BubbleShape.tailHeight)
        .frame(maxWidth: 300)
        .background(BubbleShape().fill(bubbleYellow))
        .overlay(BubbleShape().stroke(Color.black.opacity(0.85), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        .environment(\.colorScheme, .light)
    }

    private func label(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 13))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AskBox: View {
    @ObservedObject var state: BuddyState
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Ask Bonzai anything…", text: $state.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.black)
                .focused($focused)
                .onSubmit(submit)
            Button("Ask", action: submit)
                .disabled(state.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10 + BubbleShape.tailHeight)
        .frame(width: 290)
        .background(BubbleShape().fill(bubbleYellow))
        .overlay(BubbleShape().stroke(Color.black.opacity(0.85), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        .environment(\.colorScheme, .light)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand(perform: cancel)
    }
}

struct BubbleShape: Shape {
    static let tailHeight: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 12
        let bottom = rect.maxY - Self.tailHeight
        let cx = rect.midX
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX - r, y: bottom), radius: r)
        p.addLine(to: CGPoint(x: cx + 12, y: bottom))
        p.addLine(to: CGPoint(x: cx + 2, y: rect.maxY))
        p.addLine(to: CGPoint(x: cx - 8, y: bottom))
        p.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

// MARK: Click-through regions

struct HitRectKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame so the panel accepts clicks there and passes them through elsewhere.
    func hitRegion(_ id: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: HitRectKey.self, value: [id: geo.frame(in: .global)])
        })
    }
}
