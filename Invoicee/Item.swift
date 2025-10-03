//
//  Item.swift
//  Invoicee
//
//  Created by Ha Nguyen on 3/10/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
