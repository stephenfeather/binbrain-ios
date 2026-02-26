//
//  Item.swift
//  Bin Brain
//
//  Created by Stephen Feather on 2/25/26.
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
