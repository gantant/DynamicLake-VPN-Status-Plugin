import Foundation

/// Country names as the card and the glance can actually show them.
///
/// The state line is `Connected · Romania`, and both surfaces clip its tail
/// once the country is long: the lake, because a notification-sized card leaves
/// the text column the width left over by the logo and the timer's trailing
/// column, and the glance, because its header row is a fraction of that. The
/// exit lookup publishes the full CLDR name — "United Arab Emirates" — which is
/// wider than either has room for, so a long name is shown in its short form
/// and, failing that, as its ISO code.
///
/// The limit is in characters rather than points because the host owns the
/// font. At the sizes these lines render (the lake's `plain` beside a 34-point
/// logo, the glance's smaller subtitle) a character averages five to seven
/// points, so 14 keeps the lake's line inside its column and 10 does the same
/// for the narrower glance. Nothing longer than the limit is ever returned: a
/// name over it becomes its short form, and a short form over it becomes the
/// two-letter code, so the widest line is fixed no matter which country a VPN
/// exits in.
func compactCountryLabel(_ name: String, countryCode: String, limit: Int) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let short = countryShortNames[trimmed] ?? trimmed
    if short.count <= limit { return short }

    let iso = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Without a code there is nothing shorter to fall back to, and a long name
    // reads better than no name at all.
    guard !iso.isEmpty else { return short }
    return iso
}

/// Short forms for the country names too long for the state line.
///
/// Only names that do not fit are listed: anything else either fits as it is or
/// falls back to its ISO code. The spellings are the ones CLDR publishes for
/// English, which is what the exit lookup resolves through `Locale`, so the key
/// is the name that is actually in the card. Where a code would be ambiguous
/// ("SA" reads as South Africa as readily as Saudi Arabia) the table spells the
/// name out short instead.
let countryShortNames: [String: String] = [
    "United Arab Emirates": "UAE",
    "United States": "US",
    "United Kingdom": "UK",
    "Democratic Republic of the Congo": "DR Congo",
    "Congo - Kinshasa": "DR Congo",
    "Central African Republic": "CAR",
    "Dominican Republic": "Dom. Rep.",
    "Trinidad and Tobago": "Trinidad",
    "Bosnia and Herzegovina": "Bosnia",
    "Equatorial Guinea": "Eq. Guinea",
    "Papua New Guinea": "PNG",
    "Saint Kitts and Nevis": "St. Kitts",
    "Saint Vincent and the Grenadines": "St. Vincent",
    "Saudi Arabia": "Saudi",
    "South Africa": "S. Africa",
]
