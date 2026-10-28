import Foundation

// Checks for the country labels the card and the glance can show. The surfaces
// are laid out by DynamicLake, so the one thing this file can pin down is the
// line the plugin hands it: a name that fits is shown as it is, a name that
// does not is shortened, and nothing over the budget is ever sent.
//
// Build & run via tests/run.sh (no network access).

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("PASS \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

@main
struct CountryLabelTests {

    static func main() {
        testNamesThatFit()
        testLongNames()
        testBudgets()
        testDegenerateInput()
        finish()
    }

    // MARK: - Names each surface can hold as they are

    static func testNamesThatFit() {
        expect(compactCountryLabel("Romania", countryCode: "RO", limit: 14) == "Romania", "short name passes through")
        expect(compactCountryLabel("Romania", countryCode: "RO", limit: 10) == "Romania", "short name fits the glance")
        expect(compactCountryLabel("Germany", countryCode: "DE", limit: 10) == "Germany", "seven letters fit the glance")
        expect(compactCountryLabel("Switzerland", countryCode: "CH", limit: 14) == "Switzerland", "lake keeps Switzerland")
        expect(compactCountryLabel("Netherlands", countryCode: "NL", limit: 14) == "Netherlands", "lake keeps Netherlands")
    }

    // MARK: - The country that started this

    static func testLongNames() {
        expect(compactCountryLabel("United Arab Emirates", countryCode: "AE", limit: 14) == "UAE", "UAE in the lake")
        expect(compactCountryLabel("United Arab Emirates", countryCode: "AE", limit: 10) == "UAE", "UAE in the glance")
        expect(compactCountryLabel("United Arab Emirates", countryCode: "AE", limit: 3) == "UAE", "short form is kept inside its budget")
        expect(compactCountryLabel("Switzerland", countryCode: "CH", limit: 10) == "CH", "glance uses the code")
        expect(compactCountryLabel("Netherlands", countryCode: "NL", limit: 10) == "NL", "glance uses NL")
        expect(compactCountryLabel("Democratic Republic of the Congo", countryCode: "CD", limit: 10) == "DR Congo", "Congo short form")
        expect(compactCountryLabel("Trinidad and Tobago", countryCode: "TT", limit: 10) == "Trinidad", "Trinidad short form")
        expect(compactCountryLabel("Trinidad and Tobago", countryCode: "TT", limit: 6) == "TT", "Trinidad falls back to its code")
        expect(compactCountryLabel("Saudi Arabia", countryCode: "SA", limit: 10) == "Saudi", "Saudi Arabia is not SA")
        // The short form is one character over the glance's budget, so the lake
        // keeps it and the glance falls back to the code.
        expect(compactCountryLabel("Saint Vincent and the Grenadines", countryCode: "VC", limit: 14) == "St. Vincent", "long saint name shortens")
        expect(compactCountryLabel("Saint Vincent and the Grenadines", countryCode: "VC", limit: 10) == "VC", "and the glance falls back to its code")
    }

    // MARK: - Nothing over the budget

    static func testBudgets() {
        let samples = [
            ("United Arab Emirates", "AE"), ("Switzerland", "CH"), ("South Africa", "ZA"),
            ("Liechtenstein", "LI"), ("Afghanistan", "AF"), ("Guinea-Bissau", "GW"),
            ("Turkmenistan", "TM"), ("Puerto Rico", "PR"), ("Pakistan", "PK"),
            ("Bosnia and Herzegovina", "BA"), ("Equatorial Guinea", "GQ"),
        ]
        for (name, code) in samples {
            let label = compactCountryLabel(name, countryCode: code, limit: 10)
            expect(label.count <= 10, "\(name) fits the glance budget (\(label))")
            expect(("Connected · " + label).count <= 22, "\(name) keeps the glance line at 22 characters")
        }
        // Every table entry also has to survive the lake's wider budget intact.
        for (name, short) in countryShortNames {
            let label = compactCountryLabel(name, countryCode: "ZZ", limit: 14)
            expect(label.count <= 14, "\(name) fits the lake budget (\(label))")
            expect(label == short || label == "ZZ", "\(name) keeps its short form in the lake")
        }
    }

    // MARK: - Degenerate input

    static func testDegenerateInput() {
        expect(compactCountryLabel("", countryCode: "AE", limit: 10) == "", "missing name stays empty")
        expect(compactCountryLabel("   ", countryCode: "AE", limit: 10) == "", "whitespace-only name stays empty")
        expect(compactCountryLabel("  Germany  ", countryCode: "DE", limit: 10) == "Germany", "surrounding space trimmed")
        expect(compactCountryLabel("El Salvador", countryCode: " sv ", limit: 10) == "SV", "code is trimmed and uppercased")
        expect(
            compactCountryLabel("Some Very Long Place", countryCode: "", limit: 10) == "Some Very Long Place",
            "a long name with no code is still a label"
        )
    }

    static func finish() {
        if failures == 0 {
            print("country label tests passed (\(checks) checks)")
            exit(0)
        } else {
            print("country label tests FAILED (\(failures)/\(checks))")
            exit(1)
        }
    }
}
