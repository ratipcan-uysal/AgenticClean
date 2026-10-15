import CleanerCore
import SwiftUI

struct DiskSpaceChangeView: View {
  let change: DiskSpaceChange
  private var delta: String {
    guard let bytes = change.netBytes else { return L10n.text("Ölçülemedi", "Unavailable") }
    return (bytes > 0 ? "+" : bytes < 0 ? "−" : "") + Format.bytes(bytes.magnitude)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.text("Son simülatör işlemi · diskte gözlenen net değişim: ",
                     "Last simulator action · observed net disk change: ") + delta)
        .font(.callout).monospacedDigit().accessibilityIdentifier("disk.netChange")
      Text(L10n.text("Kullanılabilir alan · önce ", "Available space · before ")
        + Format.bytes(change.before?.available)
        + L10n.text(" · sonra ", " · after ") + Format.bytes(change.after?.available))
        .font(.caption).accessibilityIdentifier("disk.beforeAfter")
      if let date = change.after?.date {
        Text(date, format: .dateTime.hour().minute().second()).font(.caption)
      }
      Text(L10n.text("İşlem aralığındaki tüm disk değişikliklerini kapsar. Diğer uygulamalar ve APFS nedeniyle silinen cihaz boyutundan farklı olabilir.",
                     "Includes all disk changes during the action. Other apps and APFS can make this differ from the deleted device size."))
        .font(.caption)
    }.foregroundStyle(AgenticPalette.secondaryText)
  }
}
