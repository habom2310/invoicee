internal import SwiftUI

/// Filters binding updates to numeric characters, optionally permitting a decimal separator.
extension Binding where Value == String {
    func enforcingNumeric(allowDecimal: Bool) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue.filteredNumeric(allowDecimal: allowDecimal)
            }
        )
    }
}
