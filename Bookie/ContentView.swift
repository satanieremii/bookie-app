//
//  ContentView.swift
//  Bookie
//
//  Created by Yuliia Ieremii on 10/05/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import UIKit
import zlib

private enum BookFormat: String, Codable {
    case pdf
    case txt
    case epub
}

private enum ReaderTheme: String, Codable, CaseIterable {
    case original
    case dark
    case calm
    case paper

    var background: Color {
        switch self {
        case .original: return Color.white
        case .dark: return Color(red: 0.24, green: 0.24, blue: 0.24)
        case .calm: return Color(red: 0.84, green: 0.76, blue: 0.65)
        case .paper: return Color(red: 0.90, green: 0.90, blue: 0.90)
        }
    }

    var foreground: Color {
        self == .dark ? .white : .black
    }

    var title: String {
        switch self {
        case .original: return "Oryginalny"
        case .dark: return "Ciemny"
        case .calm: return "Spokojny"
        case .paper: return "Papierowy"
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChapterOffsetKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ReaderChapter: Codable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    var locationHint: String
    var pageIndex: Int?

    init(title: String, content: String, locationHint: String, pageIndex: Int? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.locationHint = locationHint
        self.pageIndex = pageIndex
    }
}

private struct ReaderBookmark: Codable, Hashable, Identifiable {
    let id: UUID
    var chapterIndex: Int
    var snippet: String

    init(chapterIndex: Int, snippet: String) {
        self.id = UUID()
        self.chapterIndex = chapterIndex
        self.snippet = snippet
    }
}

private struct BookItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var progress: Double
    var tags: [String]
    var playlistIDs: Set<UUID>
    var fileName: String
    var format: BookFormat
    var pageCount: Int?
    var currentPage: Int?
    var textChunks: [String]
    var currentChunk: Int
    var chapters: [ReaderChapter]
    var currentChapter: Int
    var bookmarks: [ReaderBookmark]
    var fontScale: Double
    var readerTheme: ReaderTheme
    var isFinished: Bool

    var progressPercent: Int { Int((progress * 100).rounded()) }

    func chapterIndex(containingPage pageIndex: Int) -> Int {
        let indexed = chapters.enumerated().compactMap { index, chapter -> (Int, Int)? in
            guard let chapterPage = chapter.pageIndex else { return nil }
            return (index, chapterPage)
        }
        guard !indexed.isEmpty else {
            return min(max(pageIndex, 0), max(chapters.count - 1, 0))
        }

        return indexed.last(where: { $0.1 <= pageIndex })?.0 ?? indexed[0].0
    }
}

private struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
}

private struct LibrarySnapshot: Codable {
    var books: [BookItem]
    var playlists: [Playlist]
}

private enum LibraryDiskStore {
    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BookieData", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var booksDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("Books", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var metadataURL: URL {
        appSupportDirectory.appendingPathComponent("library.json")
    }
}

@MainActor
private final class LibraryStore: ObservableObject {
    @Published var books: [BookItem] = []
    @Published var playlists: [Playlist] = []

    init() {
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: LibraryDiskStore.metadataURL),
           let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
            books = snapshot.books
            playlists = snapshot.playlists
            if refreshStoredBookStructures() {
                persist()
            }
            return
        }

        playlists = [
            Playlist(id: UUID(), name: "Tomarry", emoji: "🐍"),
        ]
        persist()
    }

    func persist() {
        let snapshot = LibrarySnapshot(books: books, playlists: playlists)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: LibraryDiskStore.metadataURL, options: [.atomic])
    }

    private func refreshStoredBookStructures() -> Bool {
        var didChange = false

        for index in books.indices {
            let fileURL = LibraryDiskStore.booksDirectory.appendingPathComponent(books[index].fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            var refreshedChapters: [ReaderChapter] = []
            var refreshedTextChunks = books[index].textChunks
            var refreshedPageCount = books[index].pageCount

            switch books[index].format {
            case .pdf:
                if let doc = PDFDocument(url: fileURL) {
                    refreshedPageCount = doc.pageCount
                    refreshedChapters = makePDFChapters(from: doc)
                }
            case .txt:
                if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
                    refreshedTextChunks = raw
                        .components(separatedBy: "\n\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if refreshedTextChunks.isEmpty {
                        refreshedTextChunks = ["This text file appears to be empty or unsupported encoding."]
                    }
                    refreshedChapters = makeTextChapters(from: refreshedTextChunks)
                }
            case .epub:
                if let epub = try? EPUBParser.parse(fileURL: fileURL) {
                    refreshedChapters = epub.chapters
                }
            }

            guard !refreshedChapters.isEmpty else { continue }

            if !chaptersMatch(books[index].chapters, refreshedChapters) {
                let oldChapter = books[index].currentChapter
                books[index].chapters = refreshedChapters
                books[index].currentChapter = min(oldChapter, max(refreshedChapters.count - 1, 0))
                didChange = true
            }

            if books[index].textChunks != refreshedTextChunks {
                books[index].textChunks = refreshedTextChunks
                didChange = true
            }

            if books[index].pageCount != refreshedPageCount {
                books[index].pageCount = refreshedPageCount
                didChange = true
            }
        }

        return didChange
    }

    private func chaptersMatch(_ lhs: [ReaderChapter], _ rhs: [ReaderChapter]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.title == right.title &&
            left.locationHint == right.locationHint &&
            left.pageIndex == right.pageIndex &&
            left.content.count == right.content.count
        }
    }

    func addPlaylist(name: String, emoji: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(Playlist(id: UUID(), name: trimmed, emoji: emoji.isEmpty ? "📚" : emoji))
        persist()
    }

    func importBook(
        pickedURL: URL,
        title: String,
        author: String,
        tags: [String],
        selectedPlaylists: Set<UUID>
    ) throws {
        let isScoped = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped { pickedURL.stopAccessingSecurityScopedResource() }
        }

        let ext = pickedURL.pathExtension.lowercased()
        let format: BookFormat = ext == "pdf" ? .pdf : (ext == "epub" ? .epub : .txt)
        let id = UUID()
        let localName = "\(id.uuidString).\(ext)"
        let destination = LibraryDiskStore.booksDirectory.appendingPathComponent(localName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: pickedURL, to: destination)

        var parsedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        var pageCount: Int?
        var textChunks: [String] = []
        var chapters: [ReaderChapter] = []

        if format == .pdf, let doc = PDFDocument(url: destination) {
            pageCount = doc.pageCount
            if parsedTitle.isEmpty,
               let pdfTitle = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               !pdfTitle.isEmpty {
                parsedTitle = pdfTitle
            }
            if parsedAuthor.isEmpty,
               let pdfAuthor = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
               !pdfAuthor.isEmpty {
                parsedAuthor = pdfAuthor
            }
            chapters = makePDFChapters(from: doc)
        } else if format == .txt {
            if let raw = try? String(contentsOf: destination, encoding: .utf8) {
                textChunks = raw
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if textChunks.isEmpty {
                textChunks = ["This text file appears to be empty or unsupported encoding."]
            }
            chapters = makeTextChapters(from: textChunks)
        } else if format == .epub {
            let epub = try EPUBParser.parse(fileURL: destination)
            if parsedTitle.isEmpty { parsedTitle = epub.title }
            if parsedAuthor.isEmpty { parsedAuthor = epub.author }
            chapters = epub.chapters
        }

        if parsedTitle.isEmpty { parsedTitle = pickedURL.deletingPathExtension().lastPathComponent }
        if parsedAuthor.isEmpty { parsedAuthor = "Unknown Author" }

        let book = BookItem(
            id: id,
            title: parsedTitle,
            author: parsedAuthor,
            progress: 0,
            tags: tags,
            playlistIDs: selectedPlaylists,
            fileName: localName,
            format: format,
            pageCount: pageCount,
            currentPage: format == .pdf ? 1 : nil,
            textChunks: textChunks,
            currentChunk: 0,
            chapters: chapters,
            currentChapter: 0,
            bookmarks: [],
            fontScale: 1.0,
            readerTheme: .original,
            isFinished: false
        )
        books.insert(book, at: 0)
        persist()
    }

    func addBookmark(_ id: UUID) {
        updateBook(id) { item in
            guard item.chapters.indices.contains(item.currentChapter) else { return }
            let chapter = item.chapters[item.currentChapter]
            let snippet = String(chapter.content.prefix(80))
            let bookmark = ReaderBookmark(chapterIndex: item.currentChapter, snippet: snippet)
            if !item.bookmarks.contains(where: { $0.chapterIndex == bookmark.chapterIndex }) {
                item.bookmarks.append(bookmark)
            }
        }
    }

    private func makePDFChapters(from doc: PDFDocument) -> [ReaderChapter] {
        guard doc.pageCount > 0 else { return [] }
        let outlineChapters = makePDFOutlineChapters(from: doc)
        if !outlineChapters.isEmpty { return outlineChapters }

        return (0..<doc.pageCount).map { index in
            let text = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ReaderChapter(
                title: "Page \(index + 1)",
                content: text,
                locationHint: "p.\(index + 1)",
                pageIndex: index
            )
        }
    }

    private func makePDFOutlineChapters(from doc: PDFDocument) -> [ReaderChapter] {
        guard let outline = doc.outlineRoot else { return [] }
        var chapters: [ReaderChapter] = []

        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                var destination = child.destination
                if destination == nil, let action = child.action as? PDFActionGoTo {
                    destination = action.destination
                }
                let page = destination?.page
                let pageIndex = page.map { doc.index(for: $0) }.flatMap { $0 >= 0 ? $0 : nil }

                if let pageIndex {
                    let pageText = doc.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    chapters.append(
                        ReaderChapter(
                            title: title.isEmpty ? "Chapter \(chapters.count + 1)" : title,
                            content: pageText,
                            locationHint: "p.\(pageIndex + 1)",
                            pageIndex: pageIndex
                        )
                    )
                }

                walk(child, level: level + 1)
            }
        }

        walk(outline, level: 0)
        return chapters.sorted { ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0) }
    }

    private func makeTextChapters(from chunks: [String]) -> [ReaderChapter] {
        let fullText = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return [] }

        let lines = fullText.components(separatedBy: .newlines)
        var chapters: [ReaderChapter] = []
        var currentTitle = "Chapter 1"
        var currentLines: [String] = []

        func flush() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            chapters.append(
                ReaderChapter(
                    title: currentTitle,
                    content: content,
                    locationHint: "\(chapters.count + 1)"
                )
            )
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isTextChapterHeading(trimmed), !currentLines.isEmpty {
                flush()
                currentTitle = trimmed
                currentLines = [line]
            } else {
                if currentLines.isEmpty, isTextChapterHeading(trimmed) {
                    currentTitle = trimmed
                }
                currentLines.append(line)
            }
        }

        flush()

        if chapters.count > 1 { return chapters }
        return [
            ReaderChapter(
                title: chapters.first?.title ?? "Text",
                content: fullText,
                locationHint: "1"
            )
        ]
    }

    private func isTextChapterHeading(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 90 else { return false }
        let patterns = [
            #"^(chapter|part|book|section)\s+([0-9ivxlcdm]+|[a-z]+)\b.*"#,
            #"^(глава|часть|раздел)\s+([0-9ivxlcdm]+|[а-яё]+)\b.*"#,
            #"^[0-9]+[\.\)]\s+\S.*"#,
            #"^[ivxlcdm]+[\.\)]\s+\S.*"#
        ]

        return patterns.contains { pattern in
            line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    func updateBook(_ id: UUID, updater: (inout BookItem) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        updater(&books[index])
        persist()
    }

    func deleteBook(_ id: UUID) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let book = books[index]
        let fileURL = LibraryDiskStore.booksDirectory.appendingPathComponent(book.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        books.remove(at: index)
        persist()
    }
}

private enum BookieTab {
    case home
    case library
    case playlists
}

struct ContentView: View {
    @StateObject private var store = LibraryStore()
    @State private var selectedTab: BookieTab = .home
    @State private var showingAddBook = false
    @State private var readerBookID: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 246 / 255, green: 241 / 255, blue: 242 / 255).ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView(showingAddBook: $showingAddBook)
                Divider()
                ActiveTabView(selectedTab: selectedTab, readerBookID: $readerBookID)
                    .environmentObject(store)
            }

            BottomTabBar(selectedTab: $selectedTab)
                .padding(.bottom, 18)
        }
        .sheet(isPresented: $showingAddBook) {
            AddBookSheet()
                .environmentObject(store)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { readerBookID != nil },
                set: { if !$0 { readerBookID = nil } }
            )
        ) {
            if let id = readerBookID {
                BookReaderSheet(bookID: id)
                    .environmentObject(store)
            }
        }
    }
}

private struct HeaderView: View {
    @Binding var showingAddBook: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image("HeaderImage")
                .resizable()
                .scaledToFill()
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipped()

            HStack {
                Text("hi, julls!⭐️")
                    .font(.cochin(size: 42))
                    .fontWeight(.bold)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button { showingAddBook = true } label: {
                    Circle()
                        .fill(Color(red: 243/255, green: 219/255, blue: 233/255))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(red: 227/255, green: 105/255, blue: 180/255))
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

private struct ActiveTabView: View {
    let selectedTab: BookieTab
    @Binding var readerBookID: UUID?

    var body: some View {
        switch selectedTab {
        case .home:
            HomeScreen(readerBookID: $readerBookID)
        case .library:
            LibraryScreen(readerBookID: $readerBookID)
        case .playlists:
            PlaylistScreen(readerBookID: $readerBookID)
        }
    }
}

private struct HomeScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var readerBookID: UUID?
    @State private var openedMenuBookID: UUID?
    @State private var openedMenuOnRight = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var playlistPickerBookID: UUID?
    @State private var showPlaylistPicker = false
    @State private var tagEditorBookID: UUID?
    @State private var newTagText = ""
    @State private var renameBookID: UUID?
    @State private var renameText = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Daily Reading pill
                HStack(spacing: 6) {
                    Circle()
                        .stroke(Color.pink, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                    Text("Daily Reading  ➡  5 minutes left")
                        .font(.workSans(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.6))
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)

                // Current / Recent заголовки
                HStack {
                    Text("Current").font(.cochin(size: 26))
                    Spacer()
                    Text("Recent").font(.cochin(size: 26))
                    Spacer().frame(width: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Горизонтальный скролл книг
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.books.prefix(5).enumerated()), id: \.element.id) { index, book in
                            VStack(alignment: .leading, spacing: 8) {
                                BookCard(book: book)
                                    .onTapGesture { readerBookID = book.id }
                                Text(book.title)
                                    .font(.workSans(size: 13, bold: true))
                                    .lineLimit(1)
                                    .frame(width: 146)
                                HStack {
                                    Text("\(book.progressPercent)%")
                                        .font(.workSans(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        openedMenuBookID = (openedMenuBookID == book.id) ? nil : book.id
                                        openedMenuOnRight = index % 2 == 1
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 146)

                                if openedMenuBookID == book.id {
                                    BookContextPopup(onRightSide: openedMenuOnRight) { action in
                                        switch action {
                                        case .share:
                                            shareItems = [book.title, "by \(book.author)"]
                                            showShareSheet = true
                                        case .addToPlaylist:
                                            playlistPickerBookID = book.id
                                            showPlaylistPicker = true
                                        case .toggleFinished:
                                            store.updateBook(book.id) { item in
                                                item.isFinished.toggle()
                                                if item.isFinished { item.progress = 1 }
                                            }
                                        case .addTag:
                                            tagEditorBookID = book.id
                                        case .rename:
                                            renameBookID = book.id
                                            renameText = book.title
                                        case .delete:
                                            store.deleteBook(book.id)
                                        }
                                        openedMenuBookID = nil
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer(minLength: 120)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let bookID = playlistPickerBookID {
                PlaylistPickerSheet(bookID: bookID)
                    .environmentObject(store)
            }
        }
        .alert("Add tag", isPresented: Binding(
            get: { tagEditorBookID != nil },
            set: { if !$0 { tagEditorBookID = nil; newTagText = "" } }
        )) {
            TextField("Tag name", text: $newTagText)
            Button("Cancel", role: .cancel) {
                tagEditorBookID = nil
                newTagText = ""
            }
            Button("Add") {
                if let id = tagEditorBookID {
                    let tag = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tag.isEmpty {
                        store.updateBook(id) { item in
                            if !item.tags.contains(tag) { item.tags.append(tag) }
                        }
                    }
                }
                tagEditorBookID = nil
                newTagText = ""
            }
        }
        .alert("Change name", isPresented: Binding(
            get: { renameBookID != nil },
            set: { if !$0 { renameBookID = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameBookID = nil }
            Button("Save") {
                if let id = renameBookID {
                    store.updateBook(id) { $0.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                renameBookID = nil
            }
        }
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PlaylistPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    let bookID: UUID

    var body: some View {
        NavigationStack {
            List(store.playlists) { playlist in
                Button {
                    store.updateBook(bookID) { book in
                        if book.playlistIDs.contains(playlist.id) {
                            book.playlistIDs.remove(playlist.id)
                        } else {
                            book.playlistIDs.insert(playlist.id)
                        }
                    }
                } label: {
                    HStack {
                        Text(playlist.emoji + "  " + playlist.name)
                            .foregroundStyle(.black)
                        Spacer()
                        if let book = store.books.first(where: { $0.id == bookID }),
                           book.playlistIDs.contains(playlist.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color(red: 0.6, green: 0.2, blue: 0.5))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct LibraryScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var readerBookID: UUID?
    @State private var tagEditorBookID: UUID?
    @State private var newTagText = ""
    @State private var playlistPickerBookID: UUID?
    @State private var showPlaylistPicker = false
    @State private var query = ""
    @State private var renameBookID: UUID?
    @State private var renameText = ""
    @State private var openedMenuBookID: UUID?
    @State private var openedMenuOnRight = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    private var filteredBooks: [BookItem] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return store.books }
        return store.books.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.author.localizedCaseInsensitiveContains(query)
            || $0.tags.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Поиск
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                    TextField("Search", text: $query)
                        .font(.workSans(size: 16))
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Color.black.opacity(0.07))
                .clipShape(Capsule())
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)

                // Грид книг
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())],
                    spacing: 24
                ) {
                    ForEach(Array(filteredBooks.enumerated()), id: \.element.id) { index, book in
                        VStack(alignment: .leading, spacing: 6) {
                            GeometryReader { geo in
                                BookCard(book: book, width: geo.size.width)
                                    .onTapGesture { readerBookID = book.id }
                            }
                            .aspectRatio(0.68, contentMode: .fit)

                            Text(book.title)
                                .font(.workSans(size: 13, bold: true))
                                .lineLimit(1)
                            HStack {
                                Text("\(book.progressPercent)%")
                                    .font(.workSans(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    openedMenuBookID = (openedMenuBookID == book.id) ? nil : book.id
                                    openedMenuOnRight = index % 2 == 1
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if openedMenuBookID == book.id {
                                BookContextPopup(onRightSide: openedMenuOnRight) { action in
                                    switch action {
                                    case .share:
                                        shareItems = [book.title, "by \(book.author)"]
                                        showShareSheet = true
                                    case .addToPlaylist:
                                        playlistPickerBookID = book.id
                                        showPlaylistPicker = true
                                    case .toggleFinished:
                                        store.updateBook(book.id) { item in
                                            item.isFinished.toggle()
                                            if item.isFinished { item.progress = 1 }
                                        }
                                    case .addTag:
                                        tagEditorBookID = book.id
                                    case .rename:
                                        renameBookID = book.id
                                        renameText = book.title
                                    case .delete:
                                        store.deleteBook(book.id)
                                    }
                                    openedMenuBookID = nil
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
        }
        .alert("Change name", isPresented: Binding(
            get: { renameBookID != nil },
            set: { if !$0 { renameBookID = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameBookID = nil }
            Button("Save") {
                if let id = renameBookID {
                    store.updateBook(id) { $0.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                renameBookID = nil
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let bookID = playlistPickerBookID {
                PlaylistPickerSheet(bookID: bookID)
                    .environmentObject(store)
            }
        }
        .alert("Add tag", isPresented: Binding(
                    get: { tagEditorBookID != nil },
                    set: { if !$0 { tagEditorBookID = nil; newTagText = "" } }
                )) {
                    TextField("Tag name", text: $newTagText)
                    Button("Cancel", role: .cancel) {
                        tagEditorBookID = nil
                        newTagText = ""
                    }
                    Button("Add") {
                        if let id = tagEditorBookID {
                            let tag = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !tag.isEmpty {
                                store.updateBook(id) { item in
                                    if !item.tags.contains(tag) { item.tags.append(tag) }
                                }
                            }
                        }
                        tagEditorBookID = nil
                        newTagText = ""
                    }
                }
            }
        }

private struct PlaylistScreen: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var readerBookID: UUID?
    @State private var showingAddPlaylist = false
    @State private var newName = ""
    @State private var newEmoji = ""
    @State private var selectedPlaylistID: UUID?
    @State private var openedMenuBookID: UUID?
    @State private var openedMenuOnRight = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var playlistPickerBookID: UUID?
    @State private var showPlaylistPicker = false
    @State private var tagEditorBookID: UUID?
    @State private var newTagText = ""
    @State private var renameBookID: UUID?
    @State private var renameText = ""

    private func circleHeaderButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: 243/255, green: 219/255, blue: 233/255))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.black)
                }
        }
    }

    var body: some View {
        Group {
            if let selectedID = selectedPlaylistID,
               let playlist = store.playlists.first(where: { $0.id == selectedID }) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack {
                            circleHeaderButton("chevron.left") { selectedPlaylistID = nil }
                            Spacer()
                            Text("\(playlist.emoji)  \(playlist.name)")
                                .font(.workSans(size: 17, bold: true))
                            Spacer()
                            circleHeaderButton("plus") { showingAddPlaylist = true }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 20)

                        let books = store.books.filter { $0.playlistIDs.contains(playlist.id) }
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())],
                            spacing: 24
                        ) {
                            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                                VStack(alignment: .leading, spacing: 6) {
                                    GeometryReader { geo in
                                        BookCard(book: book, width: geo.size.width)
                                            .onTapGesture { readerBookID = book.id }
                                    }
                                    .aspectRatio(0.68, contentMode: .fit)

                                    Text(book.title)
                                        .font(.workSans(size: 13, bold: true))
                                        .lineLimit(1)
                                    HStack {
                                        Text("\(book.progressPercent)%")
                                            .font(.workSans(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button {
                                            openedMenuBookID = (openedMenuBookID == book.id) ? nil : book.id
                                            openedMenuOnRight = index % 2 == 1
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if openedMenuBookID == book.id {
                                        BookContextPopup(onRightSide: openedMenuOnRight) { action in
                                            switch action {
                                            case .share:
                                                shareItems = [book.title, "by \(book.author)"]
                                                showShareSheet = true
                                            case .addToPlaylist:
                                                playlistPickerBookID = book.id
                                                showPlaylistPicker = true
                                            case .toggleFinished:
                                                store.updateBook(book.id) { item in
                                                    item.isFinished.toggle()
                                                    if item.isFinished { item.progress = 1 }
                                                }
                                            case .addTag:
                                                tagEditorBookID = book.id
                                            case .rename:
                                                renameBookID = book.id
                                                renameText = book.title
                                            case .delete:
                                                store.deleteBook(book.id)
                                            }
                                            openedMenuBookID = nil
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { showingAddPlaylist = true } label: {
                            Text("Add new  +")
                                .font(.workSans(size: 15))
                                .foregroundStyle(.black)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    List(store.playlists) { playlist in
                        Button {
                            selectedPlaylistID = playlist.id
                        } label: {
                            HStack(spacing: 12) {
                                Text(playlist.emoji)
                                    .font(.system(size: 20))
                                Text(playlist.name)
                                    .font(.workSans(size: 17))
                                    .foregroundStyle(.black)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.4))
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.gray.opacity(0.3))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .alert("New Playlist", isPresented: $showingAddPlaylist) {
            TextField("Name", text: $newName)
            TextField("Emoji", text: $newEmoji)
            Button("Cancel", role: .cancel) { newName = ""; newEmoji = "📚" }
            Button("Create") {
                store.addPlaylist(name: newName, emoji: newEmoji)
                newName = ""
                newEmoji = "📚"
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let bookID = playlistPickerBookID {
                PlaylistPickerSheet(bookID: bookID)
                    .environmentObject(store)
            }
        }
        .alert("Add tag", isPresented: Binding(
            get: { tagEditorBookID != nil },
            set: { if !$0 { tagEditorBookID = nil; newTagText = "" } }
        )) {
            TextField("Tag name", text: $newTagText)
            Button("Cancel", role: .cancel) {
                tagEditorBookID = nil
                newTagText = ""
            }
            Button("Add") {
                if let id = tagEditorBookID {
                    let tag = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tag.isEmpty {
                        store.updateBook(id) { item in
                            if !item.tags.contains(tag) { item.tags.append(tag) }
                        }
                    }
                }
                tagEditorBookID = nil
                newTagText = ""
            }
        }
        .alert("Change name", isPresented: Binding(
            get: { renameBookID != nil },
            set: { if !$0 { renameBookID = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameBookID = nil }
            Button("Save") {
                if let id = renameBookID {
                    store.updateBook(id) { $0.title = renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                renameBookID = nil
            }
        }
    }
}

private enum BookContextAction {
    case share
    case addToPlaylist
    case toggleFinished
    case addTag
    case rename
    case delete
}

private struct BookContextPopup: View {
    let onRightSide: Bool
    let onAction: (BookContextAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                smallAction("Share", icon: "square.and.arrow.up") { onAction(.share) }
                smallAction("Add to playlist", icon: "line.3.horizontal") { onAction(.addToPlaylist) }
            }
            Divider()
            lineAction("Finished", icon: "checkmark.square.fill", color: .green) { onAction(.toggleFinished) }
            lineAction("Add tag", icon: "tag", color: .secondary) { onAction(.addTag) }
            lineAction("Change name", icon: "pencil", color: .secondary) { onAction(.rename) }
            Divider()
            lineAction("Delete book", icon: "xmark", color: .red) { onAction(.delete) }
        }
        .padding(12)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .frame(maxWidth: .infinity, alignment: onRightSide ? .trailing : .leading)
    }

    private func smallAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.workSans(size: 10))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
        }
    }

    private func lineAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.workSans(size: 12))
                    .foregroundStyle(color == .red ? .red : .black)
            }
        }
    }
}

private struct BookCard: View {
    let book: BookItem
    var width: CGFloat = 146
    
    var body: some View {
        let height = width / 0.68
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 244/255, green: 209/255, blue: 230/255),
                        Color(red: 239/255, green: 170/255, blue: 206/255)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .shadow(color: .black.opacity(0.15), radius: 6, x: 2, y: 3)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 8)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0
                        ))
                }
            VStack(spacing: 8) {
                Text(book.title)
                    .font(.workSans(size: 14))
                    .foregroundStyle(Color(red: 147/255, green: 57/255, blue: 97/255))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                Text(book.author)
                    .font(.workSans(size: 10))
                    .foregroundStyle(Color(red: 145/255, green: 108/255, blue: 133/255))
                    .lineLimit(1)
            }
            .padding(.bottom, 16)
        }
        .frame(width: width, height: height)
    }
}

private struct BottomTabBar: View {
    @Binding var selectedTab: BookieTab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(icon: "🏠", title: "Home", tab: .home)
            tabButton(icon: "📚", title: "My library", tab: .library)
            tabButton(icon: "🎁", title: "Playlist", tab: .playlists)
        }
        .padding(6)
        .background(
            Capsule()
                .fill(Color(red: 245/255, green: 224/255, blue: 235/255).opacity(0.95))
                .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 4)
        )
        .overlay(Capsule().stroke(.white.opacity(0.65), lineWidth: 1))
        .padding(.horizontal, 32)
    }

    private func tabButton(icon: String, title: String, tab: BookieTab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 3) {
                Text(icon).font(.system(size: 22))
                Text(title)
                    .font(.workSans(size: 12, bold: true))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(selectedTab == tab
                        ? Color(red: 232/255, green: 168/255, blue: 205/255)
                        : .clear)
            )
        }
    }
}

private struct AddBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore

    @State private var title = ""
    @State private var author = ""
    @State private var rawTags = ""
    @State private var selectedPlaylists: Set<UUID> = []
    @State private var pickedURL: URL?
    @State private var showingImporter = false
    @State private var errorMessage: String?

    private let importerTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .text]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        return types
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Book file") {
                    Button(pickedURL?.lastPathComponent ?? "Choose file (PDF/EPUB/TXT)") {
                        showingImporter = true
                    }
                }
                Section("Info") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                }
                Section("Tags") {
                    TextField("comma,separated,tags", text: $rawTags)
                }
                Section("Add to playlists") {
                    ForEach(store.playlists) { playlist in
                        Toggle(
                            "\(playlist.emoji) \(playlist.name)",
                            isOn: Binding(
                                get: { selectedPlaylists.contains(playlist.id) },
                                set: { isOn in
                                    if isOn { selectedPlaylists.insert(playlist.id) } else { selectedPlaylists.remove(playlist.id) }
                                }
                            )
                        )
                    }
                }
            }
            .navigationTitle("Upload your book")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let pickedURL else { return }
                        let tags = rawTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        do {
                            try store.importBook(
                                pickedURL: pickedURL,
                                title: title,
                                author: author,
                                tags: tags,
                                selectedPlaylists: selectedPlaylists
                            )
                            dismiss()
                        } catch {
                            errorMessage = "Import failed: \(error.localizedDescription)"
                        }
                    }
                    .disabled(pickedURL == nil)
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importerTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result {
                    pickedURL = urls.first
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct BookReaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    let bookID: UUID

    @State private var showReaderMenu = false
    @State private var showControls = false
    @State private var showTOC = false
    @State private var showBookmarks = false
    @State private var showThemes = false
    @State private var jumpChapter = 0
    @State private var jumpRequest = 0

    private var book: BookItem? { store.books.first(where: { $0.id == bookID }) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let book {
                ReaderContentView(
                    book: book,
                    jumpChapter: jumpChapter,
                    jumpRequest: jumpRequest,
                    showReaderMenu: $showReaderMenu,
                    showControls: $showControls,
                    onClose: { dismiss() }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let book, showControls {
                if showReaderMenu {
                    ReaderMainMenu(
                        onTOC: { showTOC = true },
                        onBookmarks: { showBookmarks = true },
                        onThemes: { showThemes = true },
                        onBookmarkQuick: { store.addBookmark(book.id) }
                    )
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $showTOC) {
            if let book {
                ChapterListSheet(book: book) { chapter in
                    jumpChapter = chapter
                    jumpRequest += 1
                    store.updateBook(book.id) { item in
                        item.currentChapter = chapter
                        item.currentChunk = chapter
                        if let pageIndex = item.chapters[safe: chapter]?.pageIndex {
                            item.currentPage = pageIndex + 1
                            let totalPages = max(item.pageCount ?? 1, 1)
                            item.progress = min(max(Double(pageIndex + 1) / Double(totalPages), 0), 1)
                        } else {
                            let total = max(item.chapters.count, 1)
                            item.progress = Double(chapter + 1) / Double(total)
                        }
                    }
                    showTOC = false
                }
            }
        }
        .sheet(isPresented: $showBookmarks) {
            if let book {
                BookmarkListSheet(book: book) { chapter in
                    jumpChapter = chapter
                    jumpRequest += 1
                    store.updateBook(book.id) { item in
                        item.currentChapter = chapter
                        item.currentChunk = chapter
                        if let pageIndex = item.chapters[safe: chapter]?.pageIndex {
                            item.currentPage = pageIndex + 1
                            let totalPages = max(item.pageCount ?? 1, 1)
                            item.progress = min(max(Double(pageIndex + 1) / Double(totalPages), 0), 1)
                        } else {
                            let total = max(item.chapters.count, 1)
                            item.progress = Double(chapter + 1) / Double(total)
                        }
                    }
                    showBookmarks = false
                }
            }
        }
        .sheet(isPresented: $showThemes) {
            if let book {
                ThemeSettingsSheet(
                    theme: book.readerTheme,
                    fontScale: book.fontScale,
                    onThemeChanged: { theme in
                        store.updateBook(book.id) { $0.readerTheme = theme }
                    },
                    onScaleChanged: { scale in
                        store.updateBook(book.id) { $0.fontScale = scale }
                    }
                )
            }
        }
    }
}

private struct ReaderContentView: View {
    @EnvironmentObject private var store: LibraryStore
    let book: BookItem
    let jumpChapter: Int
    let jumpRequest: Int
    @Binding var showReaderMenu: Bool
    @Binding var showControls: Bool
    let onClose: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var contentOffset: CGFloat = 0
    @State private var chapterOffsets: [Int: CGFloat] = [:]
    @State private var suppressVisibleChapterUpdates = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if book.format == .pdf {
                PDFReaderView(book: book)
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                GeometryReader { offsetGeo in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: offsetGeo.frame(in: .named("scroll")).minY
                                    )
                                }
                                .frame(height: 0)

                                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                                    Text(chapter.content)
                                        .font(.charter(size: CGFloat(18 * book.fontScale)))
                                        .foregroundStyle(book.readerTheme.foreground)
                                        .lineSpacing(6)
                                        .padding(.horizontal, 22)
                                        .padding(.top, index == 0 ? 56 : 32)
                                        .padding(.bottom, 32)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                        .background(
                                            GeometryReader { chapterGeo in
                                                Color.clear.preference(
                                                    key: ChapterOffsetKey.self,
                                                    value: [index: chapterGeo.frame(in: .named("bookContent")).minY]
                                                )
                                            }
                                        )
                                }
                            }
                            .coordinateSpace(name: "bookContent")
                            .background(
                                GeometryReader { contentGeo in
                                    Color.clear
                                        .preference(key: ScrollContentHeightKey.self, value: contentGeo.size.height)
                                }
                            )
                        }
                        .coordinateSpace(name: "scroll")
                        .background(book.readerTheme.background.ignoresSafeArea())
                        .onAppear {
                            DispatchQueue.main.async {
                                proxy.scrollTo(book.currentChapter, anchor: .top)
                            }
                        }
                        .onChange(of: jumpRequest) { _, _ in
                            suppressVisibleChapterUpdates = true
                            DispatchQueue.main.async {
                                withAnimation {
                                    proxy.scrollTo(jumpChapter, anchor: .top)
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                suppressVisibleChapterUpdates = false
                                publishTextProgress(viewportHeight: geo.size.height)
                            }
                        }
                        .onPreferenceChange(ScrollContentHeightKey.self) { value in
                            contentHeight = value
                            publishTextProgress(viewportHeight: geo.size.height)
                        }
                        .onPreferenceChange(ScrollOffsetKey.self) { value in
                            contentOffset = value
                            publishTextProgress(viewportHeight: geo.size.height)
                        }
                        .onPreferenceChange(ChapterOffsetKey.self) { value in
                            chapterOffsets = value
                            publishTextProgress(viewportHeight: geo.size.height)
                        }
                        .onChange(of: book.fontScale) { _, _ in
                            DispatchQueue.main.async {
                                publishTextProgress(viewportHeight: geo.size.height)
                            }
                        }
                    }
                }
                .background(book.readerTheme.background.ignoresSafeArea())
            }
            if showControls {
                Button(action: onClose) {
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 48, height: 48)
                        .overlay { Image(systemName: "xmark").font(.title3.weight(.bold)).foregroundStyle(.black) }
                }
                .padding(.top, 8)
                .padding(.trailing, 20)
            }
        }
        .onTapGesture {
            showControls.toggle()
            if !showControls {
                showReaderMenu = false
            }
        }
        .overlay(alignment: .bottom) {
            if showControls {
                Text(pageLabel)
                    .font(.workSans(size: 14, bold: true))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.bottom, 18)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showControls && !showReaderMenu {
                Button {
                    showReaderMenu = true
                } label: {
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 48, height: 48)
                        .overlay { Image(systemName: "line.3.horizontal").foregroundStyle(.black) }
                }
                .padding(20)
            }
        }
    }

    private var pageLabel: String {
        let current = max(book.currentPage ?? (book.currentChapter + 1), 1)
        let total = max(book.pageCount ?? max(book.chapters.count, 1), 1)
        return "\(current) z \(total)"
    }

    private func publishTextProgress(viewportHeight: CGFloat) {
        guard book.format != .pdf, viewportHeight > 0, contentHeight > 0 else { return }
        let pageHeight = max(viewportHeight - 88, 1)
        let totalPages = max(Int(ceil(contentHeight / pageHeight)), 1)
        let currentPage = min(max(Int(floor(max(-contentOffset, 0) / pageHeight)) + 1, 1), totalPages)
        let currentChapter = suppressVisibleChapterUpdates ? book.currentChapter : visibleChapterIndex()
        let progress = min(max(Double(currentPage) / Double(totalPages), 0), 1)
        let chapterPageHints = calculatedChapterPageHints(pageHeight: pageHeight, totalPages: totalPages)

        guard book.currentPage != currentPage ||
              book.pageCount != totalPages ||
              book.currentChapter != currentChapter ||
              abs(book.progress - progress) > 0.001 ||
              needsChapterPageHintUpdate(chapterPageHints) else { return }

        store.updateBook(book.id) { item in
            if item.currentPage != currentPage { item.currentPage = currentPage }
            if item.pageCount != totalPages { item.pageCount = totalPages }
            if item.currentChapter != currentChapter { item.currentChapter = currentChapter }
            if abs(item.progress - progress) > 0.001 { item.progress = progress }
            for (index, pageIndex) in chapterPageHints where item.chapters.indices.contains(index) {
                if item.chapters[index].pageIndex != pageIndex {
                    item.chapters[index].pageIndex = pageIndex
                    item.chapters[index].locationHint = "\(pageIndex + 1)"
                }
            }
            if progress >= 0.999 { item.isFinished = true }
        }
    }

    private func visibleChapterIndex() -> Int {
        guard !chapterOffsets.isEmpty else { return book.currentChapter }
        let scrollY = max(-contentOffset, 0)
        let visible = chapterOffsets
            .filter { $0.value <= scrollY + 72 }
            .max { $0.value < $1.value }
        if let visible {
            return min(max(visible.key, 0), max(book.chapters.count - 1, 0))
        }
        return chapterOffsets.min { abs($0.value - scrollY) < abs($1.value - scrollY) }?.key ?? book.currentChapter
    }

    private func calculatedChapterPageHints(pageHeight: CGFloat, totalPages: Int) -> [Int: Int] {
        guard pageHeight > 0 else { return [:] }
        var hints = estimatedChapterPageHints(totalPages: totalPages)
        for (index, offset) in chapterOffsets {
            hints[index] = min(max(Int(floor(max(offset, 0) / pageHeight)), 0), max(totalPages - 1, 0))
        }
        return hints
    }

    private func estimatedChapterPageHints(totalPages: Int) -> [Int: Int] {
        let weights = book.chapters.map { max($0.content.count, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var cumulative = 0
        return weights.enumerated().reduce(into: [:]) { result, pair in
            let pageIndex = min(
                max(Int((Double(cumulative) / Double(totalWeight)) * Double(totalPages)), 0),
                max(totalPages - 1, 0)
            )
            result[pair.offset] = pageIndex
            cumulative += pair.element
        }
    }

    private func needsChapterPageHintUpdate(_ hints: [Int: Int]) -> Bool {
        hints.contains { index, pageIndex in
            guard book.chapters.indices.contains(index) else { return false }
            return book.chapters[index].pageIndex != pageIndex || book.chapters[index].locationHint != "\(pageIndex + 1)"
        }
    }
}

private struct ReaderMainMenu: View {
    let onTOC: () -> Void
    let onBookmarks: () -> Void
    let onThemes: () -> Void
    let onBookmarkQuick: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            menuButton("Spis treści", trailing: "≡", action: onTOC)
            menuButton("Zakładki i wyróżnienia", trailing: "3", action: onBookmarks)
            menuButton("Motywy i ustawienia", trailing: "Aa", action: onThemes)
            Button(action: onBookmarkQuick) {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 52, height: 52)
                    .overlay { Image(systemName: "bookmark").foregroundStyle(.black) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }

    private func menuButton(_ title: String, trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.workSans(size: 18, bold: true))
                Spacer()
                Text(trailing).font(.workSans(size: 18, bold: true))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.95))
            .clipShape(Capsule())
        }
    }
}

private struct ChapterListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: BookItem
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                BookCard(book: book, width: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.workSans(size: 16, bold: true))
                    Text("Page \(book.currentPage ?? (book.currentChapter + 1)) of \(book.pageCount ?? book.chapters.count)")
                        .font(.workSans(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            List {
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button { onSelect(index) } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.workSans(size: 16))
                                .foregroundStyle(.black)
                            Spacer()
                            Text(chapterPageLabel(index: index, chapter: chapter))
                                .font(.workSans(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.gray.opacity(0.3))
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.large])
    }

    private func chapterPageLabel(index: Int, chapter: ReaderChapter) -> String {
        if let pageIndex = chapter.pageIndex {
            return "\(pageIndex + 1)"
        }
        guard book.format != .pdf, let pageCount = book.pageCount, pageCount > 0 else {
            return chapter.locationHint
        }

        let weights = book.chapters.map { max($0.content.count, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        let cumulative = weights.prefix(index).reduce(0, +)
        let pageIndex = min(
            max(Int((Double(cumulative) / Double(totalWeight)) * Double(pageCount)), 0),
            max(pageCount - 1, 0)
        )
        return "\(pageIndex + 1)"
    }
}

private struct BookmarkListSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: BookItem
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks")
                    .font(.workSans(size: 20, bold: true))
                Spacer()
                Button { dismiss() } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            List {
                ForEach(book.bookmarks) { mark in
                    Button { onSelect(mark.chapterIndex) } label: {
                        HStack {
                            Text(book.chapters[safe: mark.chapterIndex]?.title ?? "Chapter")
                                .font(.workSans(size: 16))
                                .foregroundStyle(.black)
                            Spacer()
                            Text("\(mark.chapterIndex + 1)")
                                .font(.workSans(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.gray.opacity(0.3))
                }
            }
            .listStyle(.plain)
        }
        .presentationDetents([.large])
    }
}

private struct ThemeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let theme: ReaderTheme
    let fontScale: Double
    let onThemeChanged: (ReaderTheme) -> Void
    let onScaleChanged: (Double) -> Void
    @State private var localScale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Motywy i ustawienia").font(.workSans(size: 34, bold: true))
                Spacer()
                Button("✕") { dismiss() }.font(.workSans(size: 28, bold: true))
            }

            HStack {
                Text("a").font(.charter(size: 26))
                Slider(value: $localScale, in: 0.8...1.4, step: 0.05)
                Text("A").font(.charter(size: 36))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ReaderTheme.allCases, id: \.self) { item in
                    Button {
                        onThemeChanged(item)
                    } label: {
                        VStack(spacing: 6) {
                            Text("Aa")
                                .font(.charter(size: 48))
                                .foregroundStyle(item.foreground)
                            Text(item.title)
                                .font(.workSans(size: 22, bold: true))
                                .foregroundStyle(item.foreground)
                        }
                        .frame(maxWidth: .infinity, minHeight: 128)
                        .background(item.background)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(theme == item ? Color.black : .clear, lineWidth: 2)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(22)
        .onAppear { localScale = fontScale }
        .onChange(of: localScale) { _, value in onScaleChanged(value) }
        .presentationDetents([.fraction(0.55)])
    }
}

private struct PDFReaderView: View {
    @EnvironmentObject private var store: LibraryStore
    let book: BookItem

    var body: some View {
        PDFKitContainer(
            fileURL: LibraryDiskStore.booksDirectory.appendingPathComponent(book.fileName),
            startPage: (book.currentPage ?? 1) - 1
        ) { currentPage, totalPages in
            store.updateBook(book.id) { item in
                item.currentPage = currentPage
                item.pageCount = totalPages
                item.currentChapter = item.chapterIndex(containingPage: currentPage - 1)
                item.progress = totalPages > 0 ? Double(currentPage) / Double(totalPages) : 0
                if item.progress >= 0.999 { item.isFinished = true }
            }
        }
        .ignoresSafeArea()
    }
}

private struct PDFKitContainer: UIViewRepresentable {
    let fileURL: URL
    let startPage: Int
    let onProgress: (Int, Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: fileURL)
        if let doc = view.document, startPage >= 0, startPage < doc.pageCount, let page = doc.page(at: startPage) {
            view.go(to: page)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        context.coordinator.pdfView = view
        context.coordinator.onProgress = onProgress
        context.coordinator.publishProgress()
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        guard let doc = uiView.document,
              startPage >= 0,
              startPage < doc.pageCount,
              let targetPage = doc.page(at: startPage) else { return }
        if uiView.currentPage != targetPage {
            uiView.go(to: targetPage)
            context.coordinator.publishProgress()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onProgress: ((Int, Int) -> Void)?

        @objc func pageChanged(_ notification: Notification) {
            publishProgress()
        }

        func publishProgress() {
            guard let view = pdfView, let document = view.document, let page = view.currentPage else { return }
            onProgress?(document.index(for: page) + 1, document.pageCount)
        }
    }
}

private struct EPUBParsedBook {
    var title: String
    var author: String
    var chapters: [ReaderChapter]
}

private enum EPUBParser {
    static func parse(fileURL: URL) throws -> EPUBParsedBook {
        let archive = try TinyZIPArchive(url: fileURL)
        guard let containerData = archive.data(for: "META-INF/container.xml"),
              let containerXML = String(data: containerData, encoding: .utf8),
              let opfPath = firstMatch(in: containerXML, pattern: "full-path=\"([^\"]+)\"") else {
            throw NSError(domain: "EPUBParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid EPUB container"])
        }

        guard let opfData = archive.data(for: opfPath),
              let opfXML = String(data: opfData, encoding: .utf8) else {
            throw NSError(domain: "EPUBParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing OPF package"])
        }

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let metadataTitle = firstMatch(in: opfXML, pattern: "<dc:title[^>]*>(.*?)</dc:title>")?.htmlStripped ?? "Untitled"
        let metadataAuthor = firstMatch(in: opfXML, pattern: "<dc:creator[^>]*>(.*?)</dc:creator>")?.htmlStripped ?? "Unknown Author"

        let manifestItems = parseManifestItems(opfXML)
        let spineIds = parseSpineItemRefs(opfXML)

        let tocPath: String? = {
            if let nav = manifestItems.first(where: { $0.properties.contains("nav") }) {
                return joinPath(base: opfDirectory, relative: nav.href)
            }
            if let ncx = manifestItems.first(where: { $0.mediaType.contains("ncx") }) {
                return joinPath(base: opfDirectory, relative: ncx.href)
            }
            return nil
        }()

        let tocEntries = parseTOCEntries(archive: archive, tocPath: tocPath)

        var chapters: [ReaderChapter] = []
        if !tocEntries.isEmpty {
            chapters = tocEntries.enumerated().compactMap { index, entry in
                let resourceHref = entry.href.components(separatedBy: "#").first ?? entry.href
                let fragment = entry.href.components(separatedBy: "#").dropFirst().first
                let resourcePath = resourceHref
                guard let chapterData = archive.data(for: resourcePath) else { return nil }
                let html = String(data: chapterData, encoding: .utf8) ?? String(data: chapterData, encoding: .isoLatin1) ?? ""
                let sectionHTML = fragment.flatMap { extractHTMLSection(id: $0, from: html) } ?? html
                let text = sectionHTML.htmlStripped.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                return ReaderChapter(
                    title: entry.title.isEmpty ? "Chapter \(index + 1)" : entry.title,
                    content: text,
                    locationHint: "\(index + 1)"
                )
            }
        }

        if chapters.isEmpty {
            var tocMap: [String: String] = [:]
            for entry in tocEntries {
                let key = entry.href.components(separatedBy: "#").first ?? entry.href
                if tocMap[key] == nil { tocMap[key] = entry.title }
            }
            chapters = parseSpineChapters(
                archive: archive,
                opfDirectory: opfDirectory,
                manifestItems: manifestItems,
                spineIds: spineIds,
                tocMap: tocMap
            )
        }

        if chapters.isEmpty {
            chapters = [ReaderChapter(title: "Chapter 1", content: "Unable to parse EPUB chapter content.", locationHint: "1")]
        }

        return EPUBParsedBook(title: metadataTitle, author: metadataAuthor, chapters: chapters)
    }

    private static func parseSpineChapters(
        archive: TinyZIPArchive,
        opfDirectory: String,
        manifestItems: [ManifestItem],
        spineIds: [String],
        tocMap: [String: String]
    ) -> [ReaderChapter] {
        var chapters: [ReaderChapter] = []
        for (index, idRef) in spineIds.enumerated() {
            guard let item = manifestItems.first(where: { $0.id == idRef }) else { continue }
            let resourcePath = joinPath(base: opfDirectory, relative: item.href)
            guard let chapterData = archive.data(for: resourcePath) else { continue }
            let html = String(data: chapterData, encoding: .utf8) ?? String(data: chapterData, encoding: .isoLatin1) ?? ""
            let text = html.htmlStripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let chapterTitle = tocMap[item.href] ?? tocMap[resourcePath] ?? tocMap[(item.href as NSString).lastPathComponent] ?? "Chapter \(index + 1)"
            chapters.append(
                ReaderChapter(
                    title: chapterTitle,
                    content: text,
                    locationHint: "\(index + 1)"
                )
            )
        }
        return chapters
    }

    private struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String
        var properties: String
    }

    private struct TOCEntry {
        var title: String
        var href: String
    }

    private static func parseManifestItems(_ xml: String) -> [ManifestItem] {
        let tags = allMatches(in: xml, pattern: "<item\\s+[^>]*>")
        return tags.compactMap { tag in
            guard
                let id = attr("id", in: tag),
                let href = attr("href", in: tag),
                let mediaType = attr("media-type", in: tag)
            else { return nil }
            return ManifestItem(id: id, href: href, mediaType: mediaType, properties: attr("properties", in: tag) ?? "")
        }
    }

    private static func parseSpineItemRefs(_ xml: String) -> [String] {
        allMatches(in: xml, pattern: "<itemref\\s+[^>]*>")
            .compactMap { attr("idref", in: $0) }
    }

    private static func parseTOCEntries(archive: TinyZIPArchive, tocPath: String?) -> [TOCEntry] {
        guard let tocPath, let data = archive.data(for: tocPath) else { return [] }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let tocDirectory = (tocPath as NSString).deletingLastPathComponent
        let links = allMatches(in: xml, pattern: "<a\\s+[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>")
        if !links.isEmpty {
            return links.compactMap { match in
                guard let href = firstMatch(in: match, pattern: "href=\"([^\"]+)\"") else { return nil }
                let title = match.htmlStripped.trimmingCharacters(in: .whitespacesAndNewlines)
                return TOCEntry(title: title, href: joinPath(base: tocDirectory, relative: href))
            }
        }

        let navPoints = allMatches(in: xml, pattern: "<navPoint\\b[\\s\\S]*?</navPoint>")
        return navPoints.compactMap { navPoint in
            guard let href = firstMatch(in: navPoint, pattern: "<content\\s+[^>]*src=\"([^\"]+)\"") else { return nil }
            let title = firstMatch(in: navPoint, pattern: "<text[^>]*>(.*?)</text>")?.htmlStripped.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TOCEntry(title: title, href: joinPath(base: tocDirectory, relative: href))
        }
    }

    private static func extractHTMLSection(id: String, from html: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let startPattern = #"<[^>]+(?:id|name)\s*=\s*["']"# + escapedID + #"["'][^>]*>"#
        guard let startRegex = try? NSRegularExpression(pattern: startPattern, options: [.caseInsensitive]),
              let startMatch = startRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let startRange = Range(startMatch.range, in: html) else { return nil }

        let searchStart = startRange.lowerBound
        let remainder = String(html[searchStart...])
        let nextPattern = #"<[^>]+(?:id|name)\s*=\s*["'][^"']+["'][^>]*>"#
        guard let nextRegex = try? NSRegularExpression(pattern: nextPattern, options: [.caseInsensitive]) else {
            return remainder
        }
        let matches = nextRegex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
        guard matches.count > 1,
              let nextRange = Range(matches[1].range, in: remainder) else { return remainder }
        return String(remainder[..<nextRange.lowerBound])
    }

    private static func firstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func allMatches(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            guard let range = Range($0.range, in: source) else { return nil }
            return String(source[range])
        }
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        firstMatch(in: tag, pattern: "\(name)=\"([^\"]+)\"")
    }

    private static func joinPath(base: String, relative: String) -> String {
        let combined = base.isEmpty ? relative : (base as NSString).appendingPathComponent(relative)
        return (combined as NSString)
            .standardizingPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct TinyZIPArchive {
    private struct Entry {
        var fileName: String
        var compressionMethod: UInt16
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    private let data: Data
    private let entries: [Entry]

    init(url: URL) throws {
        self.data = try Data(contentsOf: url)
        self.entries = try TinyZIPArchive.parseCentralDirectory(from: data)
    }

    func data(for path: String) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard let entry = entries.first(where: { $0.fileName == normalized }) else { return nil }
        return extract(entry)
    }

    private func extract(_ entry: Entry) -> Data? {
        let offset = Int(entry.localHeaderOffset)
        guard data.uint32(at: offset) == 0x04034b50 else { return nil }

        let fileNameLength = Int(data.uint16(at: offset + 26))
        let extraLength = Int(data.uint16(at: offset + 28))
        let bodyStart = offset + 30 + fileNameLength + extraLength
        let bodyEnd = bodyStart + Int(entry.compressedSize)
        guard bodyStart >= 0, bodyEnd <= data.count else { return nil }

        let payload = data.subdata(in: bodyStart..<bodyEnd)
        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return payload.inflateRaw(expectedSize: Int(entry.uncompressedSize))
        default:
            return nil
        }
    }

    private static func parseCentralDirectory(from data: Data) throws -> [Entry] {
        let eocd = try findEOCD(in: data)
        let entryCount = Int(data.uint16(at: eocd + 10))
        let centralOffset = Int(data.uint32(at: eocd + 16))
        var cursor = centralOffset
        var output: [Entry] = []

        for _ in 0..<entryCount {
            guard data.uint32(at: cursor) == 0x02014b50 else { break }
            let compressionMethod = data.uint16(at: cursor + 10)
            let compressedSize = data.uint32(at: cursor + 20)
            let uncompressedSize = data.uint32(at: cursor + 24)
            let fileNameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let localHeaderOffset = data.uint32(at: cursor + 42)
            let nameRange = (cursor + 46)..<(cursor + 46 + fileNameLength)
            guard nameRange.upperBound <= data.count else { break }
            let name = String(data: data.subdata(in: nameRange), encoding: .utf8) ?? ""

            output.append(
                Entry(
                    fileName: name,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            cursor += 46 + fileNameLength + extraLength + commentLength
        }
        return output
    }

    private static func findEOCD(in data: Data) throws -> Int {
        let signature: UInt32 = 0x06054b50
        let searchStart = max(0, data.count - 66_000)
        var index = data.count - 22
        while index >= searchStart {
            if data.uint32(at: index) == signature {
                return index
            }
            index -= 1
        }
        throw NSError(domain: "TinyZIPArchive", code: 11, userInfo: [NSLocalizedDescriptionKey: "ZIP EOCD not found"])
    }
}

private extension Font {
    static func cochin(size: CGFloat) -> Font {
        .custom("Cochin", size: size)
    }

    static func workSans(size: CGFloat, bold: Bool = false) -> Font {
        let name = bold ? "WorkSans-Bold" : "WorkSans-Medium"
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: bold ? .bold : .medium)
    }

    static func charter(size: CGFloat) -> Font {
        if UIFont(name: "Charter", size: size) != nil {
            return .custom("Charter", size: size)
        }
        return .system(size: size, weight: .regular, design: .serif)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func inflateRaw(expectedSize: Int) -> Data? {
        guard !isEmpty else { return Data() }
        var stream = z_stream()
        var status: Int32

        status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        return withUnsafeBytes { sourceBuffer in
            guard let baseAddress = sourceBuffer.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(count)

            let outputCapacity = Swift.max(expectedSize, 32_768)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
            defer { buffer.deallocate() }
            stream.next_out = buffer
            stream.avail_out = uInt(outputCapacity)

            status = inflate(&stream, Z_FINISH)
            if status != Z_STREAM_END && status != Z_OK {
                return nil
            }
            let written = outputCapacity - Int(stream.avail_out)
            return Data(bytes: buffer, count: Swift.max(written, 0))
        }
    }
}

private extension String {
    var htmlStripped: String {
        var output = self
        output = output.replacingOccurrences(
            of: #"(?is)<(script|style|head|svg|math)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)<\s*(br|hr)\s*/?\s*>"#,
            with: "\n",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)</\s*(p|div|section|article|header|footer|h[1-6]|li|tr|blockquote)\s*>"#,
            with: "\n\n",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        output = output.decodingHTMLEntities
        output = output.replacingOccurrences(of: "\u{00a0}", with: " ")
        output = output.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var decodingHTMLEntities: String {
        var output = self
        let named: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&ndash;": "-",
            "&mdash;": "-",
            "&hellip;": "...",
            "&rsquo;": "'",
            "&lsquo;": "'",
            "&rdquo;": "\"",
            "&ldquo;": "\""
        ]
        for (entity, value) in named {
            output = output.replacingOccurrences(of: entity, with: value)
        }

        output = output.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: { match in
                guard let value = Int(match), let scalar = UnicodeScalar(value) else { return " " }
                return String(Character(scalar))
            }
        )
        output = output.replacingOccurrences(
            of: #"&#x([0-9A-Fa-f]+);"#,
            with: { match in
                guard let value = Int(match, radix: 16), let scalar = UnicodeScalar(value) else { return " " }
                return String(Character(scalar))
            }
        )
        return output
    }

    private func replacingOccurrences(
        of pattern: String,
        with transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let source = self
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var result = source

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(fullRange, with: transform(String(result[captureRange])))
        }
        return result
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
