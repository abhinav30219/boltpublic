import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    enum Tab: String { case home, chat, memory, more }
    /// Kept in scene storage so switching theme (which rebuilds the views) leaves you on the same tab.
    @SceneStorage("selectedTab") private var selection: Tab = .home
    /// Set by the Talk button; Chat consumes it and starts dictation.
    @State private var dictateRequest = false
    var body: some View {
        TabView(selection: $selection) {
            HomeView(onTalk: { dictateRequest = true; selection = .chat })
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            AskView(dictateRequest: $dictateRequest)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(Tab.chat)
            MemoryView().tabItem { Label("Memory", systemImage: "brain") }.tag(Tab.memory)
            MoreView().tabItem { Label("More", systemImage: "ellipsis.circle.fill") }.tag(Tab.more)
        }
        .tint(Color.accent)
        .modifier(ThemedTabBar())
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("-openChatHistory") { selection = .chat } }
        #endif
    }
}

/// Candy Pop gets a white blurred tab bar and Cozy Night a dark one; Sticker Book keeps the system bar.
private struct ThemedTabBar: ViewModifier {
    func body(content: Content) -> some View {
        switch ThemeStore.current {
        case .stickerBook:
            content
        case .candyPop:
            content
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(.regularMaterial, for: .tabBar)
                .toolbarColorScheme(.light, for: .tabBar)
        case .cozyNight:
            content
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(Color(hex: 0x1E1630).opacity(0.92), for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
        }
    }
}
