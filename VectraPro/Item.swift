//
//  Item.swift
//  VectraPro
//
//  Created by Ishant Zibal on 24/06/26.
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
