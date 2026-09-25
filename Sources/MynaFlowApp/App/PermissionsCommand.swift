import AppKit
import Foundation
import MynaFlowCore

/// `Myna Flow --print-permissions`: the permission report as JSON on stdout,
/// then exit. Runs before NSApplicationMain, so there is no status item, no
/// window and no delegate — just the same TCC and Security lookups the app
/// makes, none of which need a run loop and none of which may prompt.
///
/// Launch it through Launch Services, not by exec'ing the binary from a shell:
///
///     open -n -W --stdout /tmp/p.json -a "/Applications/Myna Flow.app" --args --print-permissions
///
/// Exec'd from a terminal the process is *responsible to* the terminal, and
/// TCC answers for the terminal's Accessibility and Input Monitoring grants —
/// which is precisely the wrong question. `-n` allows a second instance while
/// the real app runs; `-W` waits; `--stdout` is how an LSUIElement app's
/// output escapes `open`, which does not propagate the exit code either.
enum PermissionsCommand {
  static let flag = "--print-permissions"

  @MainActor static func run() -> Never {
    let snapshot = PermissionSnapshot.live(permissions: PermissionManager(), checkSeal: true)
    do {
      // FileHandle rather than print: the bytes must be flushed before exit.
      FileHandle.standardOutput.write(try snapshot.json())
      FileHandle.standardOutput.write(Data("\n".utf8))
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("print-permissions: \(error)\n".utf8))
      exit(1)
    }
  }
}
