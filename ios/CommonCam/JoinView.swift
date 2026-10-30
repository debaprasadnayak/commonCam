import CommonCamKit
import SwiftUI

/// After scanning: pick a fun name and colour, accept the terms, join.
struct JoinView: View {
    let api: APIClient
    let qrToken: String
    let onJoined: (Membership) -> Void

    @State private var displayName = FunName.random()
    @State private var colour = MemberColour.palette.randomElement()!
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Your fun name") {
                HStack {
                    TextField("Display name", text: $displayName)
                    Button("Shuffle", systemImage: "shuffle") { displayName = FunName.random() }
                        .labelStyle(.iconOnly)
                }
            }
            Section("Your colour") {
                HStack {
                    ForEach(MemberColour.palette, id: \.self) { option in
                        Circle()
                            .fill(Color(hex: option))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(.primary, lineWidth: option == colour ? 3 : 0))
                            .onTapGesture { colour = option }
                            .accessibilityAddTraits(option == colour ? .isSelected : [])
                    }
                }
            }
            Section {
                Text("""
                Photos and videos you take are shared with everyone in this group until it ends, then deleted \
                from our servers. Your fun name and colour are visible to the group. No account is created.
                """)
                .font(.footnote)
                Button("Accept and join") { Task { await join() } }
                    .disabled(isJoining || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Terms")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Join group")
    }

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            onJoined(try await api.join(qrToken: qrToken, displayName: displayName, colour: colour, consentAccepted: true))
        } catch let error as APIError {
            errorMessage = switch error.statusCode {
            case 404: "That QR code isn't a commonCam group."
            case 409: "This group is full."
            case 410: "This group has ended."
            case 429: "Too many attempts. Try again in a few minutes."
            default: "Couldn't join (error \(error.statusCode))."
            }
        } catch {
            errorMessage = "Couldn't join: \(error.localizedDescription)"
        }
    }
}
