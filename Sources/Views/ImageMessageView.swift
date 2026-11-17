import SwiftUI

/// In-view placeholder for media that can't be shown ("Can't open this file").
struct ImageMessageView: View {
    var title: String = "Can't open this file"
    var detail: String
    var fileName: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if let fileName {
                Text(fileName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }
}

/// Small delayed spinner so fast loads don't flash a progress indicator.
struct ImageLoadingIndicator: View {
    @State private var visible = false

    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled { visible = true }
            }
    }
}
