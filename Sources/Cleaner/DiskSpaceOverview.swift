import CleanerCore
import Foundation
import SwiftUI

struct DiskSpaceOverview: View {
  let review: () -> Void
  @State private var capacity: UInt64?
  @State private var available: UInt64?
  @State private var measured = false
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(L10n.text("Disk alanı", "Disk space"), systemImage: "internaldrive").font(
        .largeTitle.bold())
      HStack(spacing: 30) {
        VStack(alignment: .leading, spacing: 5) {
          Text(L10n.text("Kullanılabilir", "Available")).foregroundStyle(.secondary)
          Text(Format.bytes(available)).font(.title.bold()).monospacedDigit()
        }
        VStack(alignment: .leading, spacing: 5) {
          Text(L10n.text("Disk kapasitesi", "Volume capacity")).foregroundStyle(.secondary)
          Text(Format.bytes(capacity)).font(.title.bold()).monospacedDigit()
        }
      }
      Text(
        L10n.text(
          "Kullanıcı klasörünün bulunduğu disk · anlık ölçüm",
          "Volume containing your home folder · point-in-time reading")
      )
      .font(.caption).foregroundStyle(.secondary)
      if measured && available == nil {
        Text(L10n.text("Disk kapasitesi okunamadı.", "Volume capacity could not be read."))
          .foregroundStyle(.secondary)
      }
      Divider()
      Text(L10n.text("Derleme çıktılarını gözden geçir", "Review build outputs")).font(.title2)
      Text(
        L10n.text(
          "Diskte yer açmak ile RAM kullanımını azaltmak farklı işlemlerdir. Doğrulanmış Xcode çıktılarını inceleyip seçtiklerini Çöp Kutusu’na taşıyabilirsin. Bir sonraki derleme daha uzun sürebilir.",
          "Recovering disk space and reducing memory usage are different actions. Review verified Xcode outputs and move selected items to Trash. The next build may take longer."
        )
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button(L10n.text("Çıktıları incele…", "Review outputs…"), action: review).buttonStyle(
        .borderedProminent)
      Spacer()
    }.padding(32).frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
      .task {
        let value = await volumeSpace()
        capacity = value.0
        available = value.1
        measured = true
      }
  }
  @concurrent private func volumeSpace() async -> (UInt64?, UInt64?) {
    let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [
      .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ])
    return (
      values?.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
      values?.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil }
    )
  }
}
