import SwiftUI
import CoreBluetooth

/// Displays a list of discovered BLE peripherals and lets the user connect to one.
struct DeviceScanView: View {
    @EnvironmentObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header / scan toggle
            scanHeader

            if bleManager.discoveredPeripherals.isEmpty {
                emptyStateView
            } else {
                peripheralList
            }
        }
        .onDisappear {
            // Stop scanning when the sheet is dismissed.
            if bleManager.isScanning {
                bleManager.stopScanning()
            }
        }
    }

    // MARK: - Subviews

    private var scanHeader: some View {
        HStack {
            if bleManager.isScanning {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .scaleEffect(0.7)
                Text("スキャン中...")
                    .font(.caption2)
                    .foregroundColor(.blue)
            } else {
                Text("デバイス一覧")
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            Spacer()
            Button {
                if bleManager.isScanning {
                    bleManager.stopScanning()
                } else {
                    bleManager.startScanning()
                }
            } label: {
                Text(bleManager.isScanning ? "停止" : "スキャン開始")
                    .font(.caption2)
                    .foregroundColor(bleManager.isScanning ? .red : .blue)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(bleManager.isScanning ? "デバイスを探しています..." : "デバイスが見つかりません")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var peripheralList: some View {
        List(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
            Button {
                bleManager.connect(to: peripheral)
                dismiss()
            } label: {
                PeripheralRow(peripheral: peripheral)
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(Color(white: 0.12))
        }
        .listStyle(.plain)
    }
}

// MARK: - PeripheralRow

private struct PeripheralRow: View {
    let peripheral: CBPeripheral

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peripheral.name ?? "Unknown Device")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(peripheral.identifier.uuidString.prefix(8) + "...")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct DeviceScanView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceScanView()
            .environmentObject(BLEManager())
    }
}
