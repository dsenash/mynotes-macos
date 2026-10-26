import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var store = Store.shared
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if store.showSidebar {
                SidebarView(store: store)
                    .frame(width: store.sidebarWidth)
                    .transition(.move(edge: .leading))
                resizeHandle
            }
            DetailView(store: store)
        }
        .frame(minWidth: 760, minHeight: 480)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: store.showSidebar)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = store.sidebarWidth }
                                let proposed = (dragStartWidth ?? 270) + value.translation.width
                                store.sidebarWidth = min(420, max(200, proposed))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            )
    }
}

struct DetailView: View {
    @ObservedObject var store: Store
    @ObservedObject private var theme = Theme.shared

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store)
            Divider()
            if let id = store.activeTab {
                FormatBar()
                Divider()
                EditorView(noteID: id)
                    .id(id)
            } else {
                EmptyStateView(store: store)
            }
        }
        .background(theme.backgroundColor ?? Color(nsColor: .textBackgroundColor))
    }
}

struct TabBarView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            if !store.showSidebar {
                Button {
                    store.showSidebar = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Показать боковую панель (⌥⌘S)")
                // место под кнопки окна («светофор»)
                .padding(.leading, 78)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.openTabs, id: \.self) { id in
                        TabItemView(store: store, id: id)
                    }
                }
                .padding(.vertical, 5)
            }

            Button {
                store.newNote(in: store.selectedProject)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Новая заметка (⌘N)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(WindowDragArea())
    }
}

struct TabItemView: View {
    @ObservedObject var store: Store
    let id: UUID
    @State private var hover = false

    private var isActive: Bool { store.activeTab == id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(store.title(for: id))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button {
                store.closeTab(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(hover || isActive ? 0.8 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.primary.opacity(0.10) : (hover ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.activeTab = id }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Открыть в отдельном окне") { NoteWindows.shared.open(id) }
            Divider()
            Button("Закрыть вкладку") { store.closeTab(id) }
            Button("Закрыть остальные") { store.closeOtherTabs(except: id) }
            Button("Закрыть все") { store.closeAllTabs() }
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: GothicN.appIconImage(size: 128))
                .resizable()
                .frame(width: 96, height: 96)
            Text("MyNotes")
                .font(.system(size: 22, weight: .semibold))
            Text("Откройте заметку в боковой панели\nили создайте новую.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Новая заметка") { store.newNote(in: store.selectedProject) }
                    .keyboardShortcut(.defaultAction)
                Button("Новый проект") { store.promptNewProject(parent: nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
