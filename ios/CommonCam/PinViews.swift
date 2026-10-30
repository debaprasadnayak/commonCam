import CommonCamKit
import SwiftUI

/// How a guest found the group: a scanned QR or the host's typed PIN.
enum JoinCode {
    case qrToken(String)
    case pin(String)
}

/// Host control: PIN joining is off by default; turning it on or rotating mints a fresh PIN.
struct PinSection: View {
    let api: APIClient
    let group: EventGroup

    @State private var pin: String?
    @State private var isLoaded = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Allow joining with a PIN", isOn: Binding(get: { pin != nil }, set: { on in
                Task { await update { on ? try await api.rotatePin(for: group.id) : try await turnOff() } }
            }))
            .disabled(!isLoaded || isBusy)
            if let pin {
                Text(pin)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                    .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
                Button("Rotate PIN") { Task { await update { try await api.rotatePin(for: group.id) } } }
                    .disabled(isBusy)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        } header: {
            Text("PIN")
        } footer: {
            Text("For guests who installed the app after scanning. Rotating stops the old PIN working.")
        }
        .task {
            do {
                pin = try await api.pin(for: group.id)
                isLoaded = true
            } catch {
                errorMessage = "Couldn't load the PIN: \(error.localizedDescription)"
            }
        }
    }

    private func turnOff() async throws -> String? {
        try await api.turnOffPin(for: group.id)
        return nil
    }

    private func update(_ change: () async throws -> String?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            pin = try await change()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change the PIN: \(error.localizedDescription)"
        }
    }
}

/// Guest side: type the host's 6-character PIN instead of scanning.
struct PinEntryView: View {
    let onPin: (String) -> Void

    @State private var typed = ""

    var body: some View {
        Form {
            Text("Ask the host for the group's 6-character PIN.")
            TextField("PIN", text: $typed)
                .font(.system(.title, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onSubmit(submit)
            Button("Continue", action: submit)
                .disabled(PinCode.normalized(typed) == nil)
        }
        .navigationTitle("Enter PIN")
    }

    private func submit() {
        if let pin = PinCode.normalized(typed) { onPin(pin) }
    }
}
