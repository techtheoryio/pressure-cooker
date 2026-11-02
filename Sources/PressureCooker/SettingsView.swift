import PressureCookerCore
import ServiceManagement
import SwiftUI

private let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Pressure%20Cooker")!

enum SettingsTab: String, CaseIterable { case account, repositories, notifications, general }

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.account

    var body: some View {
        TabView(selection: $tab) {
            AccountTab().tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account)
            RepositoriesTab().tabItem { Label("Repositories", systemImage: "folder") }.tag(SettingsTab.repositories)
            NotificationsTab().tabItem { Label("Notifications", systemImage: "bell") }.tag(SettingsTab.notifications)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .formStyle(.grouped)
        .tint(.ember)
        .frame(width: 500, height: 580)
    }
}

private struct AccountTab: View {
    @State private var token = ""
    @State private var saved = Keychain.token != nil

    var body: some View {
        let viewer = store.snapshot?.viewer
        let connected = viewer != nil && store.error == nil
        Form {
            Section {
                HStack(spacing: 12) {
                    if let viewer {
                        Avatar(login: viewer, size: 40)
                    } else {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 34)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewer.map { "@\($0)" } ?? "Not connected").font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(connected ? Color.green : Color.ember).frame(width: 7, height: 7)
                            Text(connected ? "Connected via \(store.tokenSource)" : store.error ?? "Connecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                SecureField("Token", text: $token, prompt: Text(saved ? "Saved in the keychain" : "ghp_…"))
                HStack {
                    Link("Create a classic token", destination: tokenURL).font(.callout)
                    Spacer()
                    if saved { Button("Remove") { store.setToken(nil); saved = false } }
                    Button("Save") { store.setToken(token); token = ""; saved = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.isEmpty)
                }
            } header: {
                Text("Personal access token")
            } footer: {
                Text("Optional when you're signed in with the gh CLI. A classic token needs the repo and read:org scopes (and SSO authorization for orgs that enforce it). A fine-grained token covers only one account and needs read access to Pull requests and Actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RepositoriesTab: View {
    @State private var newOwner = ""
    @State private var newAuthor = ""

    var body: some View {
        @Bindable var store = store
        let repos = store.snapshot?.repos ?? []
        Form {
            Section {
                ForEach(accounts, id: \.self) { owner in
                    Toggle(isOn: Binding(
                        get: { store.owners.contains(owner) },
                        set: { $0 ? store.owners.append(owner) : store.owners.removeAll { $0 == owner } })
                    ) {
                        HStack(spacing: 8) {
                            Avatar(login: owner, size: 20)
                            Text(owner)
                        }
                    }
                }
                HStack {
                    TextField("Other user or organization", text: $newOwner).onSubmit(add)
                    Button("Add", action: add).disabled(newOwner.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Watched accounts")
            } footer: {
                Text("All repositories of a watched account are included, new ones as soon as they appear. Without any, you still see your pull requests and review requests from all of GitHub, but no pending deployments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Also show everyone else's open pull requests", isOn: $store.showAll)
            }
            Section {
                ForEach(store.hiddenAuthors, id: \.self) { author in
                    LabeledContent(author) {
                        Button("Show Again") { store.hiddenAuthors.removeAll { $0 == author } }
                    }
                }
                HStack {
                    TextField("User or bot, e.g. renovate", text: $newAuthor).onSubmit(addAuthor)
                    Button("Hide", action: addAuthor).disabled(newAuthor.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Hidden authors")
            } footer: {
                Text("Their pull requests are left out of review requests and everyone else's. Right-click a pull request to hide its author.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !repos.isEmpty {
                Section("Repositories") {
                    ForEach(store.owners, id: \.self) { owner in
                        let own = repos.filter { $0.lowercased().hasPrefix(owner.lowercased() + "/") }
                        if !own.isEmpty {
                            DisclosureGroup {
                                ForEach(own, id: \.self) { repo in
                                    Toggle(String(repo.dropFirst(owner.count + 1)), isOn: Binding(
                                        get: { !store.excluded.contains(repo) },
                                        set: { if $0 { store.excluded.remove(repo) } else { store.excluded.insert(repo) } }))
                                }
                            } label: {
                                LabeledContent(owner, value: "\(own.filter { !store.excluded.contains($0) }.count) of \(own.count)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The signed-in user and their orgs, plus whatever was added by hand.
    private var accounts: [String] {
        let known = store.snapshot?.accounts ?? []
        return known + store.owners.filter { owner in !known.contains { $0.caseInsensitiveCompare(owner) == .orderedSame } }
    }

    private func add() {
        let owner = newOwner.trimmingCharacters(in: .whitespaces)
        newOwner = ""
        guard !owner.isEmpty, !store.owners.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else { return }
        store.owners.append(owner)
    }

    private func addAuthor() {
        let author = newAuthor.trimmingCharacters(in: .whitespaces)
        newAuthor = ""
        guard !author.isEmpty, !store.hiddenAuthors.contains(where: { normalizedLogin($0) == normalizedLogin(author) }) else { return }
        store.hiddenAuthors.append(author)
    }
}

private struct NotificationsTab: View {
    @AppStorage("notifyFailing") private var failing = true
    @AppStorage("notifyReady") private var ready = true
    @AppStorage("notifyReviews") private var reviews = true
    @AppStorage("notifyDeployments") private var deployments = true

    var body: some View {
        Form {
            Section {
                toggle("A deployment waits for my approval", "hand.raised.fill", .ember, $deployments)
                toggle("Checks fail on one of my pull requests", "xmark.octagon.fill", .red, $failing)
                toggle("One of my pull requests is ready to merge", "checkmark.seal.fill", .green, $ready)
                toggle("Someone requests my review", "eye.fill", .purple, $reviews)
            } header: {
                Text("Notify me when")
            } footer: {
                if !isBundled { Text("Notifications only work in the bundled app.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func toggle(_ title: String, _ symbol: String, _ color: Color, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            }
        }
    }
}

private struct GeneralTab: View {
    @AppStorage("refreshMinutes") private var minutes = 2.0
    @AppStorage("SUEnableAutomaticChecks") private var checkForUpdates = true  // Sparkle's own keys
    @AppStorage("SUAutomaticallyUpdate") private var installUpdates = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $minutes) {
                    ForEach([1.0, 2, 5, 10, 15], id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                            NSLog("Pressure Cooker: login item: \(error)")
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                    .disabled(!isBundled)
            }
            Section("Updates") {
                Toggle("Check GitHub for updates once a day", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, v in updater.updater.automaticallyChecksForUpdates = v }
                Toggle("Install updates automatically", isOn: $installUpdates)
                    .onChange(of: installUpdates) { _, v in updater.updater.automaticallyDownloadsUpdates = v }
                    .disabled(!checkForUpdates)
                Button("Check Now") { updater.checkForUpdates(nil) }
            }
            .disabled(!canUpdate)
            Section {
                Link("Pressure Cooker on GitHub", destination: githubURL)
            }
        }
    }
}
