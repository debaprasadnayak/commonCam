import CommonCamKit
import SwiftUI
import VisionKit

/// In-app QR scanner. Falls back to pasting the link where the camera scanner is unavailable (e.g. Simulator).
struct ScannerView: View {
    let onToken: (String) -> Void

    @State private var pastedLink = ""

    var body: some View {
        Group {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner { url in
                    if let token = JoinLink.qrToken(from: url) { onToken(token) }
                }
                .ignoresSafeArea()
            } else {
                Form {
                    Text("Camera scanning isn't available here. Paste the group's join link instead.")
                    TextField("https://…/join/…", text: $pastedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Continue") {
                        if let url = URL(string: pastedLink), let token = JoinLink.qrToken(from: url) { onToken(token) }
                    }
                }
            }
        }
        .navigationTitle("Scan QR")
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onURL: (URL) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onURL: onURL) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onURL: (URL) -> Void
        init(onURL: @escaping (URL) -> Void) { self.onURL = onURL }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                if let payload = barcode.payloadStringValue, let url = URL(string: payload) { onURL(url) }
            }
        }
    }
}
