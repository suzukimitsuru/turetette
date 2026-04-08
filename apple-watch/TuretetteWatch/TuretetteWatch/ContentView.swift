import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var motionManager: MotionManager
    @EnvironmentObject var alarmManager: AlarmManager

    @State private var showScanView = false
    @State private var showAlarmView = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 8) {
                    // Connection status
                    connectionStatusView

                    // Distance indicator
                    distanceView

                    // Motion status
                    motionStatusView

                    // Action button
                    actionButtonView
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showScanView) {
            DeviceScanView()
                .environmentObject(bleManager)
        }
        .fullScreenCover(isPresented: $showAlarmView) {
            AlarmView()
                .environmentObject(bleManager)
                .environmentObject(alarmManager)
        }
        // Trigger alarm when out of range AND motion detected
        .onChange(of: bleManager.isOutOfRange) { outOfRange in
            if outOfRange && motionManager.isWalking && bleManager.isConnected {
                alarmManager.startAlarm(reason: "BLEデバイスが離れました")
            }
        }
        .onChange(of: motionManager.isWalking) { walking in
            if walking && bleManager.isOutOfRange && bleManager.isConnected {
                alarmManager.startAlarm(reason: "BLEデバイスが離れました")
            }
        }
        .onChange(of: alarmManager.isAlarmActive) { active in
            showAlarmView = active
        }
    }

    // MARK: - Subviews

    private var connectionStatusView: some View {
        HStack {
            Circle()
                .fill(bleManager.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(bleManager.isConnected
                 ? (bleManager.connectedPeripheral?.name ?? "接続済み")
                 : "未接続")
                .font(.caption2)
                .foregroundColor(bleManager.isConnected ? .green : .gray)
                .lineLimit(1)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var distanceView: some View {
        VStack(spacing: 4) {
            if bleManager.isConnected {
                Text(String(format: "%.1f m", bleManager.estimatedDistance))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(bleManager.isOutOfRange ? .red : .white)

                Text("RSSI: \(bleManager.rssi) dBm")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Signal strength bar
                signalBarsView(rssi: bleManager.rssi)
            } else {
                Text("-- m")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)
                Text("デバイス未接続")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.12))
        )
    }

    private func signalBarsView(rssi: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(index: index, rssi: rssi))
                    .frame(width: 6, height: CGFloat(6 + index * 4))
            }
        }
    }

    private func barColor(index: Int, rssi: Int) -> Color {
        let thresholds = [-90, -80, -70, -60]
        if rssi >= thresholds[index] {
            return rssi < -65 ? .orange : .green
        }
        return Color(white: 0.3)
    }

    private var motionStatusView: some View {
        HStack(spacing: 8) {
            Label(
                motionManager.isWalking ? "動いています" : "静止中",
                systemImage: motionManager.isWalking ? "figure.walk" : "figure.stand"
            )
            .font(.caption2)
            .foregroundColor(motionManager.isWalking ? .yellow : .secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var actionButtonView: some View {
        Group {
            if bleManager.isConnected {
                Button(action: {
                    bleManager.disconnect()
                }) {
                    Text("切断")
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red, lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: {
                    bleManager.startScanning()
                    showScanView = true
                }) {
                    Text("デバイスをスキャン")
                        .font(.caption)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.bottom, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(BLEManager())
            .environmentObject(MotionManager())
            .environmentObject(AlarmManager())
    }
}
