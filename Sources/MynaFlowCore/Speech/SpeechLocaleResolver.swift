import Foundation

/// Picks the speech locale from the Mac's own language settings.
///
/// Myna Flow has no language picker and should not need one: the Mac already knows
/// what its owner speaks. This turns `Locale.preferredLanguages` into one of
/// the locales `SpeechTranscriber` actually supports, or falls back to en-US.
///
/// Pure, and takes the supported set as a parameter, because
/// `SpeechTranscriber.supportedLocales` is async and this must stay testable.
public enum SpeechLocaleResolver {
  public static let fallbackIdentifier = "en-US"

  /// Which region to assume when the user named a language but no usable
  /// region. A table rather than a rule: "region equals the language
  /// uppercased" happens to work for fr-FR and it-IT, but there is no en-EN,
  /// and picking the first supported region alphabetically would hand an
  /// American user en-AU.
  static let defaultRegionByLanguage: [String: String] = [
    "en": "US", "es": "ES", "fr": "FR", "de": "DE", "it": "IT",
    "pt": "BR", "ja": "JP", "ko": "KR", "zh": "CN", "yue": "CN",
  ]

  /// UN M.49 and other region codes that appear in `preferredLanguages` but
  /// never in a supported locale. `es-419` (Latin America) is the common one.
  static let regionAliases: [String: String] = ["419": "MX"]

  /// The best supported locale for this Mac.
  ///
  /// - Parameters:
  ///   - preferredLanguages: `Locale.preferredLanguages`, in the user's order.
  ///   - regionHint: `Locale.current.region?.identifier`. Distinct from the
  ///     language: a Mac set to English while living in Germany reports
  ///     language en and region DE.
  ///   - supported: identifiers from `SpeechTranscriber.supportedLocales`.
  /// - Returns: an identifier drawn from `supported`, in its original spelling.
  public static func resolve(
    preferredLanguages: [String], regionHint: String?, supported: [String]
  ) -> String {
    // Index the supported set by language, remembering each entry's original
    // spelling so we hand back exactly what the API gave us.
    var regionsByLanguage: [String: [(region: String, original: String)]] = [:]
    for identifier in supported {
      let parts = normalize(identifier).split(separator: "-").map(String.init)
      guard let language = parts.first else { continue }
      let region = parts.count > 1 ? parts[1] : ""
      regionsByLanguage[language, default: []].append((region, identifier))
    }
    for key in regionsByLanguage.keys {
      regionsByLanguage[key]?.sort { $0.region < $1.region }
    }

    let hint = regionHint.map { normalizeRegion($0) }

    for preferred in preferredLanguages {
      let parts = normalize(preferred).split(separator: "-").map(String.init)
      guard let language = parts.first, let candidates = regionsByLanguage[language]
      else { continue }

      // Any subtag after the language that looks like a region: this skips
      // scripts (zh-Hans-CN) and variants (en-US-POSIX).
      let requested = parts.dropFirst().first { isRegionSubtag($0) }.map(normalizeRegion)

      for region in [requested, hint, defaultRegionByLanguage[language]?.lowercased()] {
        guard let region,
          let match = candidates.first(where: { $0.region == region })
        else { continue }
        return match.original
      }
      // The language is supported but none of the regions are. Any variant of
      // the right language beats falling through to English.
      if let first = candidates.first { return first.original }
    }

    if let english = supported.first(where: { normalize($0) == "en-us" }) { return english }
    return supported.sorted().first ?? fallbackIdentifier
  }

  /// Lowercase, underscores to hyphens, `@`-keywords dropped.
  private static func normalize(_ identifier: String) -> String {
    let base = identifier.split(separator: "@").first.map(String.init) ?? identifier
    return base.replacingOccurrences(of: "_", with: "-").lowercased()
  }

  private static func normalizeRegion(_ region: String) -> String {
    let lowered = region.lowercased()
    return regionAliases[lowered] .map { $0.lowercased() } ?? lowered
  }

  /// Regions are two letters or three digits. Scripts are four letters
  /// (Hans, Hant) and variants are longer (POSIX), so both are excluded.
  private static func isRegionSubtag(_ subtag: String) -> Bool {
    (subtag.count == 2 && subtag.allSatisfy(\.isLetter))
      || (subtag.count == 3 && subtag.allSatisfy(\.isNumber))
  }
}
