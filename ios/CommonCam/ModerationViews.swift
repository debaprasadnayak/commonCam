import CommonCamKit
import SwiftUI

/// What is being reported, for the report sheet.
struct ReportTarget: Identifiable {
    enum Kind { case item(GalleryItem), member(id: String, name: String) }
    let kind: Kind

    var id: String {
        switch kind {
        case .item(let item): "item-\(item.id)"
        case .member(let id, _): "member-\(id)"
        }
    }

    var title: String {
        switch kind {
        case .item(let item): "Report photo by \(item.contributor.displayName)"
        case .member(_, let name): "Report \(name)"
        }
    }
}

/// Asks for a reason, files the report and shows the takedown contact. Reported photos are hidden until the host reviews them.
struct ReportSheet: View {
    let api: APIClient
    let groupID: String
    let target: ReportTarget
    var onReported: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var sending = false
    @State private var errorMessage: String?

    private static let suggestions = ["Inappropriate", "Harassment or bullying", "Shows me without consent", "Spam"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { reason = suggestion }
                            .foregroundStyle(reason == suggestion ? Color.accentColor : .primary)
                    }
                    TextField("Or describe the problem", text: $reason, axis: .vertical)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                TakedownContactSection()
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") { Task { await send() } }
                        .disabled(sending || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            switch target.kind {
            case .item(let item): _ = try await api.reportItem(item.id, in: groupID, reason: reason)
            case .member(let id, _): _ = try await api.reportMember(id, in: groupID, reason: reason)
            }
            onReported()
            dismiss()
        } catch {
            errorMessage = "Couldn't send the report."
        }
    }
}

/// The published contact for takedown requests (App Review Guideline 1.2).
struct TakedownContactSection: View {
    var body: some View {
        Section {
            Link(Contact.takedownEmail, destination: Contact.takedownMailURL)
        } header: {
            Text("Takedown requests")
        } footer: {
            Text("Email us to have content removed.")
        }
    }
}

/// Report and block actions for a gallery item, for a context menu.
struct ItemModerationMenu: View {
    let api: APIClient
    let groupID: String
    let item: GalleryItem
    let report: (ReportTarget) -> Void
    let changed: () async -> Void

    var body: some View {
        Button("Report photo…", systemImage: "flag") { report(ReportTarget(kind: .item(item))) }
        if let memberID = item.contributor.memberId {
            Button("Block \(item.contributor.displayName)", systemImage: "hand.raised", role: .destructive) {
                Task {
                    try? await api.block(memberID: memberID, in: groupID)
                    await changed()
                }
            }
        }
    }
}

/// Host/co-host: open reports with restore or delete. Polls while visible.
struct ReportsSection: View {
    let api: APIClient
    let group: EventGroup

    @State private var reports: [Report] = []
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if reports.isEmpty { Text("No reports").foregroundStyle(.secondary) }
            ForEach(reports) { report in
                HStack {
                    if let item = report.item {
                        AsyncImage(url: item.downloadUrl) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(width: 44, height: 44)
                            .pendingReviewBlur(true)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading) {
                        Text(report.item.map { "Photo by \($0.contributor.displayName)" } ?? report.member.map { "Member \($0.displayName)" } ?? "Report")
                        Text(report.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(report.item == nil ? "Dismiss" : "Restore", systemImage: "arrow.uturn.backward.circle") { decide(report, .restore) }
                        .labelStyle(.iconOnly)
                    if report.item != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) { decide(report, .delete) }
                            .labelStyle(.iconOnly).tint(.red)
                    }
                }
                .buttonStyle(.borderless)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } header: {
            Text(reports.isEmpty ? "Reports" : "Reports (\(reports.count))")
        } footer: {
            Text("Reported photos and photos flagged as possibly sensitive on the uploader's phone are hidden from guests until you restore or delete them.")
        }
        .task {
            while !Task.isCancelled {
                if let latest = try? await api.openReports(of: group.id) { reports = latest }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func decide(_ report: Report, _ decision: ReportDecision) {
        Task {
            do {
                _ = try await api.review(report.id, in: group.id, decision)
                reports = (try? await api.openReports(of: group.id)) ?? reports.filter { $0.id != report.id }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't update the report."
            }
        }
    }
}
