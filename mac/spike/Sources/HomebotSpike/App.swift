import SwiftUI

@main
struct HomebotSpikeApp: App {
  @StateObject private var probes = Probes()

  var body: some Scene {
    WindowGroup("Homebot Spike") {
      SpikeView().environmentObject(probes).frame(minWidth: 640, minHeight: 480)
        .task { probes.runAll() }
    }
  }
}

struct SpikeView: View {
  @EnvironmentObject var probes: Probes

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Homebot S0 spike").font(.title2.weight(.semibold))
      Text("Listening on port \(String(Probes.port)). Results: ~/Library/Application Support/HomebotSpike/results.jsonl")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Register login item") { probes.registerLoginItem() }
        Button("Unregister") { probes.unregisterLoginItem() }
        Button("Login item status") { probes.loginItemStatus() }
      }
      HStack {
        Button("Keychain write") { probes.keychainWrite() }
        Button("Keychain read") { probes.keychainRead() }
        Button("Release awake") { probes.releaseAwake() }
        Button("Run all") { probes.runAll() }
      }
      List(probes.results) { r in
        VStack(alignment: .leading, spacing: 2) {
          Text("\(r.ok ? "✓" : "✗") \(r.probe)").font(.body.monospaced())
          Text(r.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
    .padding(20)
  }
}
