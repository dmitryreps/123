import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var isOn = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn ? Color.yellow : Color.white.opacity(0.55))
                Button(action: toggle) {
                    Circle()
                        .fill(isOn ? Color.yellow : Color.white.opacity(0.16))
                        .frame(width: 240, height: 240)
                        .overlay(
                            Image(systemName: isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(isOn ? Color.black : Color.white)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? "Turn flashlight off" : "Turn flashlight on")
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .onAppear {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
        .onDisappear {
            try? setTorch(false)
            isOn = false
        }
    }

    private func toggle() {
        errorText = nil
        let next = !isOn
        do {
            try setTorch(next)
            isOn = next
        } catch {
            errorText = error.localizedDescription
            isOn = false
        }
    }

    private func setTorch(_ on: Bool) throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw TorchError.noCamera
        }
        guard device.hasTorch else {
            throw TorchError.noTorch
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if on {
            try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
    }
}

private enum TorchError: LocalizedError {
    case noCamera
    case noTorch

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera on this device."
        case .noTorch:
            return "This device has no flashlight."
        }
    }
}
