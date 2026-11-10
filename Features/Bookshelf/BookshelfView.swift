//
//  BookshelfView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit
import UniformTypeIdentifiers

struct BookshelfView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.horizontalSizeClass) private var contentSizeClass
    @Environment(UserConfig.self) private var userConfig
    @State private var viewModel = BookshelfViewModel()
    @State private var showDictionaries = false
    @State private var showAnkiSettings = false
    @State private var showAppearance = false
    @State private var showAdvanced = false
    @State private var showAbout = false
    @State private var showShelfManagement = false
    @State private var selectedTab = 0
    @State private var focusDictionarySearch = false
    @State private var setInitialTab = false
    @State private var navigationPath = NavigationPath()
    @State private var dictionaryRoute = DictionaryRoute()
    @State private var isSelecting = false
    @State private var selectedBooks = Set<BookMetadata>()
    @State private var showBulkDeleteConfirmation = false
    @State private var sasayakiBook: BookMetadata?
    @Binding var pendingImportURL: URL?
    @Binding var pendingRemoteImportURL: URL?
    @Binding var pendingLookup: String?
    @Binding var pendingTab: Int?
    /// An article URL shared into the app ("Save as article"); the News tab saves and opens it.
    @Binding var pendingNewsURL: String?
    
    var body: some View {
        TabView(selection: Binding(get: { selectedTab }, set: { newTab in
            if newTab == 1 && selectedTab == 1 {
                focusDictionarySearch.toggle()
            }
            selectedTab = newTab
        })) {
            Tab("Books", systemImage: "books.vertical", value: 0) {
                NavigationStack(path: $navigationPath) {
                    ScrollView {
                        let sections = viewModel.shelfSections(sortedBy: userConfig.bookshelfSortOption, showReading: userConfig.bookshelfShowReading)
                        if viewModel.books.isEmpty && !HttpSyncCloudBooks.shared.hasRecords {
                            ContentUnavailableView {
                                Label("No Books", systemImage: "books.vertical")
                            } description: {
                                Text("Import manga using the \(Image(systemName: "plus")) button to start reading.")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 160)
                        } else {
                            ForEach(sections) { section in
                                if section.books.count > 0 {
                                    ShelfView(
                                        viewModel: viewModel,
                                        section: section,
                                        showTitle: sections.count > 1,
                                        isSelecting: isSelecting,
                                        selectedBooks: $selectedBooks,
                                        pendingLookup: $pendingLookup,
                                        pendingTab: $pendingTab,
                                        onMatch: { sasayakiBook = $0 }
                                    )
                                }
                            }
                        }
                        CloudBookshelfView(installedBooks: viewModel.books, sortOption: userConfig.bookshelfSortOption)
                    }
                    .navigationTitle("Books")
                    .scrollIndicators(.hidden)
                    .toolbar {
                        toolbarContent
                    }
                    .onAppear {
                        viewModel.loadBooks()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hoshiLibraryChanged)) { _ in
                        // A downloaded manga moves from Not downloaded onto its shelf.
                        withAnimation(.snappy) { viewModel.loadBooks() }
                    }
                    .fileImporter(
                        isPresented: $viewModel.isImporting,
                        allowedContentTypes: [UTType(filenameExtension: "cbz") ?? .data, .zip, .folder],
                        allowsMultipleSelection: true,
                        onCompletion: viewModel.importMangaBundles
                    )
                    .fileImporter(
                        isPresented: $viewModel.isImportingEpub,
                        allowedContentTypes: [.epub],
                        allowsMultipleSelection: true,
                        onCompletion: viewModel.importBooks
                    )
                    .sheet(isPresented: $showShelfManagement) {
                        ShelfManagementView(viewModel: viewModel)
                    }
                    .sheet(item: $sasayakiBook) { book in
                        SasayakiMatchView(book: book, viewModel: viewModel)
                    }
                    .alert(
                        "Delete \(selectedBooks.count) book(s)?",
                        isPresented: $showBulkDeleteConfirmation
                    ) {
                        Button("Delete", role: .destructive) {
                            viewModel.deleteBooks(selectedBooks)
                            clearSelection()
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
                .onChange(of: selectedTab) {
                    clearSelection()
                }
                .environment(\.horizontalSizeClass, contentSizeClass)
            }
            
            // Tag 3 keeps the existing Books/Dictionary/Settings tags (0/1/2) that quick actions and
            // pendingTab rely on; the declaration order puts News second.
            Tab("News", systemImage: "newspaper", value: 3) {
                NavigationStack {
                    NewsView(pendingSharedURL: $pendingNewsURL)
                }
                .environment(\.horizontalSizeClass, contentSizeClass)
            }

            Tab("Dictionary", systemImage: "character.magnify.ja", value: 1) {
                NavigationStack {
                    DictionarySearchView(
                        initialQuery: dictionaryRoute.query,
                        initialAutofocus: dictionaryRoute.autofocus,
                        shouldFocus: focusDictionarySearch
                    )
                    .id(dictionaryRoute.id)
                }
                .environment(\.horizontalSizeClass, contentSizeClass)
            }
            
            if PodcastStore.shared.enabled {
                Tab("Podcasts", systemImage: "headphones", value: 4) {
                    PodcastsView().environment(\.horizontalSizeClass, contentSizeClass)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: 2) {
                NavigationStack {
                    List {
                        Button {
                            showDictionaries = true
                        } label: {
                            Label("Dictionaries", systemImage: "character.book.closed.ja")
                        }
                        .foregroundStyle(.primary)
                        Button {
                            showAnkiSettings = true
                        } label: {
                            Label("Anki", systemImage: "tray.full")
                        }
                        .foregroundStyle(.primary)
                        Button {
                            showAppearance = true
                        } label: {
                            Label("App & reading", systemImage: "paintpalette")
                        }
                        .foregroundStyle(.primary)
                        NavigationLink {
                            MangaReaderSettingsView()
                        } label: {
                            Label("Manga", systemImage: "book.pages")
                        }.accessibilityIdentifier("settings-manga")
                        NavigationLink {
                            AppearanceView(userConfig: userConfig, showDismiss: false)
                        } label: {
                            Label("EPUB", systemImage: "book")
                        }.accessibilityIdentifier("settings-epub")
                        Button {
                            showAdvanced = true
                        } label: {
                            Label("Advanced", systemImage: "gearshape.2")
                        }
                        .foregroundStyle(.primary)
                        
                        NavigationLink {
                            PopupCardsView(userConfig: userConfig)
                        } label: {
                            Label("Popup Cards", systemImage: "rectangle.on.rectangle")
                        }.accessibilityIdentifier("settings-popup-cards")
                        Section {
                            Link(destination: URL(string: "https://github.com/Manhhao/Hoshi-Reader/issues")!) {
                                Label("Report an Issue", systemImage: "exclamationmark.bubble")
                            }
                            NavigationLink {
                                DiagnosticsView()
                            } label: {
                                Label("Diagnostics", systemImage: "stethoscope")
                            }.accessibilityIdentifier("settings-diagnostics")
                            Button {
                                showAbout = true
                            } label: {
                                Label("About", systemImage: "info.circle")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationDestination(isPresented: $showDictionaries) {
                        DictionaryView()
                    }
                    .navigationDestination(isPresented: $showAnkiSettings) {
                        AnkiView()
                    }
                    .navigationDestination(isPresented: $showAdvanced) {
                        AdvancedView()
                    }
                    .navigationDestination(isPresented: $showAbout) {
                        AboutView()
                    }
                    .navigationDestination(isPresented: $showAppearance) {
                        AppReadingSettingsView(userConfig: userConfig)
                    }
                }
                .environment(\.horizontalSizeClass, contentSizeClass)
            }
        }
        // Give the tab controller its own bottom bar instead of sharing the iPad toolbar.
        // Restore the real size class inside every tab so tablet readers and split layouts
        // retain their normal dimensions and presentations.
        .environment(\.horizontalSizeClass, UIDevice.current.userInterfaceIdiom == .pad ? .compact : contentSizeClass)
        .task(id: PodcastStore.shared.configID) { await PodcastStore.shared.monitorAccess() }
        .onChange(of: PodcastStore.shared.enabled) { _, enabled in if !enabled && selectedTab == 4 { selectedTab = 0 } }

        .onChange(of: pendingTab) { _, tab in
            if let tab {
                selectedTab = tab
                pendingTab = nil
            }
        }
        .onChange(of: pendingNewsURL, initial: true) { _, url in
            // Through pendingTab rather than selectedTab so an open reader on the Books tab closes.
            if url != nil {
                pendingTab = 3
            }
        }
        .onChange(of: pendingLookup) { _, text in
            if let text {
                selectedTab = 1
                dictionaryRoute = DictionaryRoute(
                    query: text,
                    autofocus: text.isEmpty
                )
                pendingLookup = nil
            }
        }
        .onChange(of: pendingImportURL) { _, url in
            if let url {
                navigationPath = NavigationPath()
                let ext = url.pathExtension.lowercased()
                if ext == "colpkg" || ext == "apkg" {
                    do {
                        try AnkiManager.shared.importAnkiBackup(from: url)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.shouldShowError = true
                    }
                } else if ext == "cbz" || ext == "zip" {
                    viewModel.importMangaBundles(result: .success([url]))
                } else {
                    viewModel.importBook(result: .success(url))
                }
                // Manga imports finish on a background worker. Its consumed Inbox file
                // is removed after the worker releases it; EPUB/Anki remain synchronous.
                if ext != "cbz" && ext != "zip" { viewModel.clearInbox() }
                pendingImportURL = nil
            }
        }
        .onChange(of: pendingRemoteImportURL) { _, url in
            if let url {
                navigationPath = NavigationPath()
                viewModel.importRemoteBook(from: url)
                pendingRemoteImportURL = nil
            }
        }
        .alert("Error", isPresented: $viewModel.shouldShowError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("", isPresented: $viewModel.shouldShowSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.successMessage)
        }
        .overlay {
            if viewModel.isSyncing {
                LoadingOverlay("Syncing...")
            }
            if viewModel.isDownloading {
                LoadingOverlay("Downloading EPUB...")
            }
            if let importBooksProgress = viewModel.importBooksProgress {
                LoadingOverlay(importBooksProgress)
            }
        }
        .onAppear {
            guard !setInitialTab else {
                return
            }
            selectedTab = userConfig.dictionaryTabDefault ? 1 : 0
            setInitialTab = true
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { StatisticsOverviewView() } label: { Image(systemName: "chart.bar") }
                .accessibilityLabel("Statistics")
        }
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    clearSelection()
                }
                .fontWeight(.semibold)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewModel.moveBooks(selectedBooks, to: nil)
                        clearSelection()
                    } label: {
                        Label("None", systemImage: "tray")
                    }
                    ForEach(viewModel.shelves, id: \.name) { shelf in
                        Button {
                            viewModel.moveBooks(selectedBooks, to: shelf.name)
                            clearSelection()
                        } label: {
                            Label(shelf.name, systemImage: "folder")
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Move to shelf")
                .disabled(selectedBooks.isEmpty)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBulkDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete selected books")
                .disabled(selectedBooks.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                HttpSyncBookshelfButton()
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Sort books", selection: Bindable(userConfig).bookshelfSortOption) {
                        ForEach(SortOption.allCases) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    }
                    Button {
                        withAnimation(.default.speed(2)) { isSelecting = true }
                    } label: {
                        Label("Select books", systemImage: "checklist")
                    }
                    Button {
                        showShelfManagement = true
                    } label: {
                        Label("Manage shelves", systemImage: "folder.badge.gearshape")
                    }
                    Section {
                        Button { viewModel.isImportingEpub = true } label: {
                            Label("Import EPUB", systemImage: "book")
                        }
                    }
                } label: {
                    Label("Bookshelf options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("bookshelf-options")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.isImporting = true } label: {
                    Label("Add manga", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("bookshelf-add-manga")
            }
        }
    }
    
    private func clearSelection() {
        withAnimation(.default.speed(2)) {
            isSelecting = false
            selectedBooks.removeAll()
        }
    }
}

private struct DictionaryRoute {
    let id = UUID()
    let query: String
    let autofocus: Bool
    
    init(query: String = "", autofocus: Bool = true) {
        self.query = query
        self.autofocus = autofocus
    }
}
