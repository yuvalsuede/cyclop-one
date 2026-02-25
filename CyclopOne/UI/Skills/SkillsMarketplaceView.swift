import SwiftUI

// MARK: - SkillsMarketplaceViewModel

@MainActor
final class SkillsMarketplaceViewModel: ObservableObject {
    @Published var installedPackages: [SkillPackage] = []
    @Published var marketplaceEntries: [SkillMarketplaceClient.MarketplaceSkillEntry] = []
    @Published var isLoadingMarketplace = false
    @Published var marketplaceError: String?
    @Published var selectedCategory: SkillCategory? = nil
    @Published var searchText = ""

    // Installation flow state
    @Published var pendingApprovalPackage: SkillPackage? = nil
    @Published var pendingScanResult: SkillSafetyScanner.ScanResult? = nil
    @Published var isInstalling = false
    @Published var installError: String?

    // Generate skill alert
    @Published var showGenerateComingSoon = false

    // MARK: - Computed

    var filteredEntries: [SkillMarketplaceClient.MarketplaceSkillEntry] {
        var entries = marketplaceEntries
        if let cat = selectedCategory {
            entries = entries.filter { $0.category.lowercased() == cat.rawValue }
        }
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            entries = entries.filter {
                $0.name.lowercased().contains(lower) ||
                $0.description.lowercased().contains(lower) ||
                $0.author.lowercased().contains(lower) ||
                $0.tags.contains { $0.lowercased().contains(lower) }
            }
        }
        return entries
    }

    var installedNames: Set<String> {
        Set(installedPackages.map { $0.name })
    }

    // MARK: - Actions

    func loadInstalled() async {
        let packages = await SkillRegistry.shared.allPackages
        self.installedPackages = packages
    }

    func loadMarketplace() async {
        guard !isLoadingMarketplace else { return }
        isLoadingMarketplace = true
        marketplaceError = nil

        do {
            let index = try await SkillMarketplaceClient.shared.fetchIndex()
            self.marketplaceEntries = index.skills
        } catch {
            self.marketplaceError = error.localizedDescription
        }

        isLoadingMarketplace = false
    }

    func install(_ entry: SkillMarketplaceClient.MarketplaceSkillEntry) async {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil

        do {
            let pkg = try await SkillMarketplaceClient.shared.install(entry: entry)
            // Run safety scan and show approval sheet
            let scanResult = await SkillSafetyScanner.shared.scan(package: pkg)
            self.pendingApprovalPackage = pkg
            self.pendingScanResult = scanResult
        } catch {
            self.installError = error.localizedDescription
        }

        isInstalling = false
        // Refresh installed list
        await loadInstalled()
    }

    func approveInstall() async {
        guard let pkg = pendingApprovalPackage,
              let scan = pendingScanResult else { return }

        // Persist approval
        SkillApprovalInfo.saveApproval(
            name: pkg.name,
            version: pkg.manifest.version,
            scanResult: scan
        )
        // Enable in registry
        await SkillRegistry.shared.enable(pkg.name)
        // Clear pending
        pendingApprovalPackage = nil
        pendingScanResult = nil
        // Refresh
        await loadInstalled()
    }

    func cancelInstall() {
        pendingApprovalPackage = nil
        pendingScanResult = nil
    }

    func toggleEnabled(_ package: SkillPackage) async {
        if package.isEnabled {
            await SkillRegistry.shared.disable(package.name)
        } else {
            await SkillRegistry.shared.enable(package.name)
        }
        await loadInstalled()
    }

    func remove(_ package: SkillPackage) async {
        do {
            try await SkillMarketplaceClient.shared.uninstall(name: package.name)
        } catch {
            // Built-in or user skills may not be removable via marketplace client — ignore
        }
        await loadInstalled()
    }
}

// MARK: - SkillsMarketplaceView

/// Main marketplace UI — fits inside the FloatingDot popover at 360px width.
struct SkillsMarketplaceView: View {
    @StateObject private var vm = SkillsMarketplaceViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                    Button(action: { selectedTab = idx }) {
                        VStack(spacing: 2) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12))
                            Text(tab.title)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(selectedTab == idx ? .accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.primary.opacity(0.04))

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case 0: InstalledTab(vm: vm)
                case 1: BrowseTab(vm: vm)
                case 2: NewSkillTab(vm: vm)
                default: EmptyView()
                }
            }
        }
        .frame(width: 360)
        // Approval sheet
        .sheet(isPresented: Binding(
            get: { vm.pendingApprovalPackage != nil && vm.pendingScanResult != nil },
            set: { if !$0 { vm.cancelInstall() } }
        )) {
            if let pkg = vm.pendingApprovalPackage, let scan = vm.pendingScanResult {
                SkillApprovalSheet(
                    package: pkg,
                    scanResult: scan,
                    onApprove: {
                        Task { await vm.approveInstall() }
                    },
                    onCancel: { vm.cancelInstall() }
                )
            }
        }
        // Error alert for install errors
        .alert("Installation Error", isPresented: Binding(
            get: { vm.installError != nil },
            set: { if !$0 { vm.installError = nil } }
        )) {
            Button("OK") { vm.installError = nil }
        } message: {
            if let err = vm.installError {
                Text(err)
            }
        }
        .task { await vm.loadInstalled() }
    }

    private struct Tab {
        let title: String
        let icon: String
    }

    private let tabs: [Tab] = [
        Tab(title: "Installed", icon: "checklist"),
        Tab(title: "Browse", icon: "magnifyingglass"),
        Tab(title: "New", icon: "wand.and.sparkles"),
    ]
}

// MARK: - InstalledTab

private struct InstalledTab: View {
    @ObservedObject var vm: SkillsMarketplaceViewModel

    var body: some View {
        ScrollView {
            if vm.installedPackages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No skills installed")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Browse the marketplace to add skills.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(vm.installedPackages, id: \.name) { pkg in
                        InstalledSkillRow(pkg: pkg, vm: vm)
                        Divider().opacity(0.3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: 340)
        .refreshable { await vm.loadInstalled() }
    }
}

// MARK: - InstalledSkillRow

private struct InstalledSkillRow: View {
    let pkg: SkillPackage
    @ObservedObject var vm: SkillsMarketplaceViewModel
    @State private var isEnabled: Bool
    @State private var showDetails = false

    init(pkg: SkillPackage, vm: SkillsMarketplaceViewModel) {
        self.pkg = pkg
        self.vm = vm
        self._isEnabled = State(initialValue: pkg.isEnabled)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isEnabled) { _, newValue in
                    // Sync toggle state with registry
                    _ = newValue
                    Task { await vm.toggleEnabled(pkg) }
                }
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(pkg.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if pkg.isBuiltIn {
                        Text("built-in")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(pkg.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // "..." context menu
            Menu {
                Button("View Details") { showDetails = true }
                if !pkg.isBuiltIn {
                    Divider()
                    Button("Remove", role: .destructive) {
                        Task { await vm.remove(pkg) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showDetails) {
            InstalledSkillDetailView(pkg: pkg)
        }
    }
}

// MARK: - InstalledSkillDetailView

private struct InstalledSkillDetailView: View {
    let pkg: SkillPackage
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(pkg.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text("v\(pkg.manifest.version)")
                .font(.caption)
                .foregroundColor(.secondary)

            if let author = pkg.manifest.author {
                Label(author, systemImage: "person")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(pkg.description)
                .font(.system(size: 11))

            if !pkg.triggers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Triggers")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(pkg.triggers.prefix(5), id: \.self) { trigger in
                        Text(trigger)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(4)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 340, height: 280)
    }
}

// MARK: - BrowseTab

private struct BrowseTab: View {
    @ObservedObject var vm: SkillsMarketplaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search skills...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !vm.searchText.isEmpty {
                    Button(action: { vm.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CategoryChip(title: "All", icon: "square.grid.2x2", isSelected: vm.selectedCategory == nil) {
                        vm.selectedCategory = nil
                    }
                    ForEach(SkillCategory.allCases, id: \.self) { cat in
                        CategoryChip(
                            title: cat.displayName,
                            icon: cat.icon,
                            isSelected: vm.selectedCategory == cat
                        ) {
                            vm.selectedCategory = (vm.selectedCategory == cat) ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.3)

            // Content area
            if vm.isLoadingMarketplace {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading marketplace...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else if let error = vm.marketplaceError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                    Text("Failed to load marketplace")
                        .font(.system(size: 12, weight: .medium))
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 20)
                    Button("Retry") {
                        Task { await vm.loadMarketplace() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else if vm.filteredEntries.isEmpty && !vm.marketplaceEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No skills match your search")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else if vm.marketplaceEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Tap to load marketplace")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.filteredEntries) { entry in
                            VStack(spacing: 0) {
                                SkillCardView(
                                    entry: entry,
                                    isInstalled: vm.installedNames.contains(entry.name)
                                ) {
                                    Task { await vm.install(entry) }
                                }
                                .padding(.horizontal, 12)
                                Divider()
                                    .opacity(0.3)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
            }
        }
        .task { await vm.loadMarketplace() }
    }
}

// MARK: - CategoryChip

private struct CategoryChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NewSkillTab

private struct NewSkillTab: View {
    @ObservedObject var vm: SkillsMarketplaceViewModel
    @State private var descriptionText = ""
    @State private var showComingSoon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Generate a Custom Skill", systemImage: "wand.and.sparkles")
                    .font(.system(size: 12, weight: .semibold))

                Text("Describe what you want to automate and Cyclop One will generate a skill package for you.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $descriptionText)
                .font(.system(size: 11))
                .frame(height: 80)
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text("Describe what you want to automate...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer()
                Button {
                    showComingSoon = true
                } label: {
                    Label("Generate Skill", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Spacer()

            // Info footer
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("Skills run in a macOS sandbox. You'll review permissions before activation.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxHeight: 320)
        .alert("Coming Soon", isPresented: $showComingSoon) {
            Button("OK") {}
        } message: {
            Text("Skill generation with AI is coming in a future update. Stay tuned!")
        }
    }
}
