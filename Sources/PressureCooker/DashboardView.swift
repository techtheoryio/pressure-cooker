import AppKit
import PressureCookerCore
import SwiftUI

extension Color {
    static let ember = Color(red: 1, green: 0.353, blue: 0.173)  // #FF5A2C, the icon's orange
}

/// The tiles double as filters: click one to see only that.
private enum Focus { case approvals, failing, ready, reviews }

/// The list behind the menu bar icon (compact) and in the window; both show the same thing.
struct DashboardView: View {
    let compact: Bool
    @State private var filter = ""
    @State private var focus: Focus?

    var body: some View {
        let view = VStack(spacing: 0) {
            header
            if let s = store.snapshot { tiles(s) }
            searchField
            if let error = store.error, store.snapshot != nil { ErrorBanner(text: error) }
            content.frame(maxHeight: .infinity)
        }
        .tint(.ember)
        if compact {
            view.frame(width: 400, height: 600)
        } else {
            view.frame(minWidth: 420, idealWidth: 560, minHeight: 480, idealHeight: 760)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: menuBarIcon)
                .renderingMode(.template)
                .resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.ember)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pressure Cooker").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            Spacer()
            HStack(spacing: 2) {
                if store.loading {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
                }
                if compact { HeaderButton(symbol: "macwindow", help: "Open in a window") { Windows.dashboard() } }
                HeaderButton(symbol: "gearshape", help: "Settings") { Windows.settings() }
                if compact {
                    Menu {
                        Button("Check for Updates…") { updater.checkForUpdates(nil) }.disabled(!canUpdate)
                        Divider()
                        Button("Quit Pressure Cooker") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 26, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(.secondary)
                    .fixedSize()
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        guard let s = store.snapshot else { return store.error == nil ? "Connecting…" : "Not connected" }
        let need = switch s.attention {
        case 0: "All calm"
        case 1: "1 thing needs you"
        default: "\(s.attention) things need you"
        }
        if store.loading { return need + " · refreshing…" }
        return need + (store.lastRefresh.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    // MARK: Tiles

    private func tiles(_ s: Snapshot) -> some View {
        HStack(spacing: 8) {
            tile(.approvals, s.deployments.count, "Approvals", "hand.raised.fill", .ember)
            tile(.failing, s.mine.filter { $0.status == .failing }.count, "Failing", "xmark.octagon.fill", .red)
            tile(.ready, s.mine.filter { $0.status == .ready }.count, "Ready", "checkmark.seal.fill", .green)
            tile(.reviews, s.reviews.count + s.unreviewed.count, "Reviews", "eye.fill", .purple)
        }
        .padding(.horizontal, 12)
    }

    private func tile(_ kind: Focus, _ count: Int, _ label: String, _ symbol: String, _ color: Color) -> some View {
        let on = focus == kind
        return Button {
            withAnimation(.snappy(duration: 0.2)) { focus = on ? nil : kind }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(count)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(count > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    Spacer(minLength: 0)
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(count > 0 ? color : .secondary.opacity(0.5))
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? color.opacity(0.16) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? color.opacity(0.55) : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Show everything" : "Show only \(label.lowercased())")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by title, repository or author", text: $filter).textFieldStyle(.plain)
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        if let s = store.snapshot {
            let show = { (kind: Focus) in focus == nil || focus == kind }
            let runs = show(.approvals) ? s.deployments.filter { matches($0.repo, $0.title, $0.workflow, $0.actor, $0.environments.joined()) } : []
            let mine = s.mine.filter { pr in
                matches(pr) && (focus == nil || (focus == .failing && pr.status == .failing) || (focus == .ready && pr.status == .ready))
            }
            let reviews = show(.reviews) ? s.reviews.filter(matches) : []
            let unreviewed = show(.reviews) ? s.unreviewed.filter(matches) : []
            let up = Set(s.unreviewed.map(\.id))
            let others = focus == nil ? s.others.filter { !up.contains($0.id) && matches($0) } : []
            let running = focus == nil ? s.running.filter { matches($0.repo, $0.title, $0.workflow, $0.actor, $0.ref) } : []
            if runs.isEmpty && running.isEmpty && mine.isEmpty && reviews.isEmpty && unreviewed.isEmpty && others.isEmpty {
                if filter.isEmpty && focus == nil {
                    Placeholder(title: "Nothing under pressure", message: "No open pull requests and nobody waiting for you.")
                } else {
                    Placeholder(title: "Nothing here", message: "Nothing matches right now.", action: ("Show everything", { filter = ""; focus = nil }))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !runs.isEmpty {
                            SectionHeader(title: "Waiting for your approval", count: runs.count)
                            ForEach(runs) { DeploymentRow(run: $0) }
                        }
                        if !running.isEmpty {
                            SectionHeader(title: "Deploying now", count: running.count)
                            ForEach(running) { RunningRow(run: $0) }
                        }
                        if !mine.isEmpty {
                            SectionHeader(title: "My pull requests", count: mine.count)
                            ForEach(mine) { PRRow(pr: $0, showAuthor: false) }
                        }
                        if !reviews.isEmpty {
                            SectionHeader(title: "Review requested", count: reviews.count)
                            ForEach(reviews) { pr in PRRow(pr: pr).contextMenu { hide(pr) } }
                        }
                        if !unreviewed.isEmpty {
                            SectionHeader(title: "Waiting for a review", count: unreviewed.count)
                            ForEach(unreviewed) { pr in
                                PRRow(pr: pr).contextMenu {
                                    Button("Skip — I won't review this") { store.skipped.insert(pr.id) }
                                    hide(pr)
                                }
                            }
                        }
                        if !others.isEmpty {
                            SectionHeader(title: "Everyone else", count: others.count)
                            ForEach(others) { pr in
                                PRRow(pr: pr).contextMenu {
                                    if store.skipped.contains(pr.id) {
                                        Button("Review After All") { store.skipped.remove(pr.id) }
                                    }
                                    hide(pr)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
            }
        } else if let error = store.error {
            Placeholder(title: "Connect GitHub", message: error, action: ("Open Settings", { Windows.settings() }))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func hide(_ pr: PullRequest) -> some View {
        Button("Hide Pull Requests by \(pr.author)") { store.hiddenAuthors.append(pr.author) }
    }

    private func matches(_ pr: PullRequest) -> Bool { matches(pr.title, pr.repo, pr.author, "#\(pr.number)") }

    private func matches(_ fields: String...) -> Bool {
        filter.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(filter) }
    }
}

// MARK: - Pieces

private struct HeaderButton: View {
    let symbol: String, help: String, action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct SectionHeader: View {
    let title: String, count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// One clickable line: tinted status glyph, title, details, and age (plus who) on the right. Opens on GitHub.
private struct ItemRow: View {
    let url: URL, symbol: String, color: Color, title: String, details: Text, date: Date
    var person: String?
    var highlight = false
    @State private var hover = false

    var body: some View {
        Link(destination: url) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    details.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(age(date)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    if let person { Avatar(login: person, size: 16) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var background: Color {
        if highlight { return Color.ember.opacity(hover ? 0.16 : 0.09) }
        return Color.primary.opacity(hover ? 0.06 : 0)
    }
}

struct PRRow: View {
    let pr: PullRequest
    var showAuthor = true

    var body: some View {
        let status = pr.status
        ItemRow(url: pr.url, symbol: status.symbol, color: status.color, title: pr.title,
                details: Text("\(Text(status.label).foregroundStyle(status.color))  \(pr.repo) #\(String(pr.number))"),
                date: pr.updatedAt, person: showAuthor ? pr.author : nil)
    }
}

struct DeploymentRow: View {
    let run: PendingDeployment

    var body: some View {
        ItemRow(url: run.url, symbol: "hand.raised.fill", color: .ember, title: run.title,
                details: Text("\(Text(run.environments.joined(separator: ", ")).foregroundStyle(Color.ember).fontWeight(.semibold))  \(run.repo) · \(run.workflow)"),
                date: run.createdAt, person: run.actor.isEmpty ? nil : run.actor, highlight: true)
    }
}

struct RunningRow: View {
    let run: RunningDeploy

    var body: some View {
        ItemRow(url: run.url, symbol: run.isRelease ? "shippingbox.fill" : "arrow.triangle.2.circlepath", color: .blue, title: run.title,
                details: Text("\(Text(run.isRelease ? "release" : run.ref).foregroundStyle(Color.blue).fontWeight(.semibold))  \(run.repo) · \(run.workflow)"),
                date: run.startedAt, person: run.actor.isEmpty ? nil : run.actor)
    }
}

struct Avatar: View {
    let login: String
    var size: CGFloat = 16

    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
            image.resizable()
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        .help(login)
    }
}

private struct Placeholder: View {
    let title: String, message: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: menuBarIcon)
                .renderingMode(.template)
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.ember.opacity(0.85))
                .padding(.bottom, 4)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ember)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ember.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// "now", "5m", "3h", "2d", "4w", "1y".
private func age(_ date: Date) -> String {
    let s = max(0, Int(Date.now.timeIntervalSince(date)))
    return switch s {
    case ..<60: "now"
    case ..<3600: "\(s / 60)m"
    case ..<86400: "\(s / 3600)h"
    case ..<604_800: "\(s / 86400)d"
    case ..<31_536_000: "\(s / 604_800)w"
    default: "\(s / 31_536_000)y"
    }
}

extension PRStatus {
    var label: String {
        switch self {
        case .failing: "Checks failing"
        case .conflicts: "Conflicts"
        case .draft: "Draft"
        case .changesRequested: "Changes requested"
        case .running: "Checks running"
        case .needsReview: "Awaiting review"
        case .ready: "Ready to merge"
        }
    }

    var symbol: String {
        switch self {
        case .failing: "xmark"
        case .conflicts: "exclamationmark"
        case .draft: "pencil"
        case .changesRequested: "arrow.uturn.backward"
        case .running: "ellipsis"
        case .needsReview: "eye"
        case .ready: "checkmark"
        }
    }

    var color: Color {
        switch self {
        case .failing: .red
        case .conflicts, .changesRequested: .orange
        case .draft: .gray
        case .running: .blue
        case .needsReview: .purple
        case .ready: .green
        }
    }
}
