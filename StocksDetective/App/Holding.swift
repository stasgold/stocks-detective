import Foundation
import SwiftData
import DetectiveKit

@Model
final class Holding {
    @Attribute(.unique) var symbol: String
    var name: String
    var shares: Double
    var costBasis: Double?
    var sectorRaw: String
    var addedAt: Date

    init(symbol: String, name: String, shares: Double, costBasis: Double?, sector: Sector) {
        self.symbol = symbol.uppercased()
        self.name = name
        self.shares = shares
        self.costBasis = costBasis
        self.sectorRaw = sector.rawValue
        self.addedAt = Date()
    }

    var sector: Sector {
        get { Sector(rawValue: sectorRaw) ?? .broadMarket }
        set { sectorRaw = newValue.rawValue }
    }

    var input: HoldingInput {
        HoldingInput(symbol: symbol, sector: sector, shares: shares, costBasis: costBasis)
    }
}

enum DemoPortfolio {
    static let holdings: [(String, String, Double, Double)] = [
        ("AAPL", "Apple Inc.", 40, 172),
        ("NVDA", "NVIDIA Corporation", 25, 98),
        ("MSFT", "Microsoft Corporation", 15, 390),
        ("TSLA", "Tesla, Inc.", 12, 240),
        ("JPM", "JPMorgan Chase & Co.", 20, 185),
    ]
}
