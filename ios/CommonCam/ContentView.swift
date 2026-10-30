import CommonCamKit
import SwiftUI

struct ContentView: View {
    let api: APIClient

    @State private var groups: [EventGroup] = []
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Create free Taster group") {
                        Task { await createGroup() }
                    }
                    .disabled(isCreating)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("My groups") {
                    ForEach(groups) { group in
                        VStack(alignment: .leading) {
                            Text("\(group.tier.capitalized) · \(group.state)").font(.headline)
                            Text("\(group.peopleCap) people · \(ByteCountFormatter.string(fromByteCount: group.storageCapBytes, countStyle: .binary))")
                            Text("Ends \(group.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("commonCam")
            .task { await loadGroups() }
            .refreshable { await loadGroups() }
        }
    }

    private func loadGroups() async {
        do {
            groups = try await api.myGroups()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load groups: \(error.localizedDescription)"
        }
    }

    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }
        do {
            groups.insert(try await api.createTasterGroup(), at: 0)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create group: \(error.localizedDescription)"
        }
    }
}
