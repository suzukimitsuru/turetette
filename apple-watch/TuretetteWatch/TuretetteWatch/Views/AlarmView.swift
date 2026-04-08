import SwiftUI

/// Full-screen alarm view shown while the alarm is active.
/// The user must tap "停止" to silence the alarm.
struct AlarmView: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var alarmManager: AlarmManager

    // Pulsing animation state
    @State private var isPulsing: Bool = false

    var body: some View {
        ZStack {
            // Red background
            Color.red.ignoresSafeArea()

            VStack(spacing: 10) {
                Spacer()

                // Pulsing alarm icon
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: isPulsing ? 70 : 50, height: isPulsing ? 70 : 50)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }

                Text("アラーム")
                    .font(.headline)
                    .foregroundColor(.white)
                    .fontWeight(.bold)

                // Alarm reason
                Text(alarmManager.alarmReason)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                // RSSI / distance info
                if bleManager.isConnected {
                    VStack(spacing: 2) {
                        Text(String(format: "距離: %.1f m", bleManager.estimatedDistance))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                        Text("RSSI: \(bleManager.rssi) dBm")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                // Stop button
                Button(action: {
                    alarmManager.stopAlarm()
                }) {
                    Text("停止")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            isPulsing = true
        }
        .onDisappear {
            isPulsing = false
        }
    }
}

struct AlarmView_Previews: PreviewProvider {
    static var previews: some View {
        let alarm = AlarmManager()
        alarm.startAlarm(reason: "BLEデバイスが離れました")
        return AlarmView()
            .environmentObject(BLEManager())
            .environmentObject(alarm)
    }
}
