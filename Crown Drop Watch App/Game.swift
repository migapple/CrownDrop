import SwiftUI
import Combine
import WatchKit

// MARK: - Constantes & palette

enum Grid {
    static let cols = 7
    static let rows = 12
}

enum Palette {
    static let ink       = Color(red: 7/255,   green: 5/255,   blue: 16/255)   // #070510
    static let gold      = Color(red: 201/255, green: 164/255, blue: 92/255)   // #c9a45c
    static let parchment = Color(red: 232/255, green: 220/255, blue: 192/255)
    static let rust      = Color(red: 181/255, green: 83/255,  blue: 60/255)
    static let slate     = Color(red: 74/255,  green: 122/255, blue: 156/255)
    static let sage      = Color(red: 107/255, green: 143/255, blue: 94/255)
    static let empty     = Color.white.opacity(0.06)
}

// MARK: - Pièces (formes originales, pas de tétriminos)

struct Cell: Hashable {
    var x: Int
    var y: Int
}

struct Shape {
    let cells: [Cell]
    let color: Color
    let rotates: Bool
}

enum Shapes {
    static let all: [Shape] = [
        Shape(cells: [Cell(x: -1, y: 0), Cell(x: 0, y: 0), Cell(x: 1, y: 0)],
              color: Palette.gold, rotates: true),                       // barre de 3
        Shape(cells: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 0, y: 1)],
              color: Palette.rust, rotates: true),                       // coin
        Shape(cells: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1)],
              color: Palette.slate, rotates: false),                     // carré
        Shape(cells: [Cell(x: -1, y: 0), Cell(x: 0, y: 0)],
              color: Palette.parchment, rotates: true)                   // domino
    ]
    static let weights = [4, 4, 3, 3]

    static func random() -> Shape {
        var r = Int.random(in: 0..<weights.reduce(0, +))
        for (i, w) in weights.enumerated() {
            if r < w { return all[i] }
            r -= w
        }
        return all[0]
    }
}

struct Piece {
    var shape: Shape
    var cells: [Cell]
    var origin: Cell

    var blocks: [Cell] {
        cells.map { Cell(x: $0.x + origin.x, y: $0.y + origin.y) }
    }
}

// MARK: - Moteur de jeu

final class Game: ObservableObject {
    enum State { case ready, playing, paused, over }

    @Published private(set) var board: [[Color?]] = Game.emptyBoard()
    @Published private(set) var current: Piece?
    @Published private(set) var next: Shape = Shapes.random()
    @Published private(set) var score = 0
    @Published private(set) var lines = 0
    @Published private(set) var state: State = .ready
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "crownDrop.best")

    private var accumulator: TimeInterval = 0

    var level: Int { lines / 8 + 1 }
    var interval: TimeInterval { max(0.15, 0.85 - Double(level - 1) * 0.07) }

    var ghost: Piece? {
        guard var p = current else { return nil }
        while true {
            var n = p
            n.origin.y += 1
            if fits(n) { p = n } else { return p }
        }
    }

    // MARK: Cycle de vie

    func start() {
        if score > best {                     // garde le record si on recommence en cours de partie
            best = score
            UserDefaults.standard.set(best, forKey: "crownDrop.best")
        }
        board = Game.emptyBoard()
        score = 0
        lines = 0
        accumulator = 0
        next = Shapes.random()
        state = .playing
        spawn()
    }

    func pause() {
        if state == .playing { state = .paused }
    }

    /// Remet le jeu sur l'écran d'accueil (en gardant le record).
    func reset() {
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "crownDrop.best")
        }
        board = Game.emptyBoard()
        current = nil
        score = 0
        lines = 0
        accumulator = 0
        state = .ready
    }

    func resume() {
        if state == .paused { accumulator = 0; state = .playing }
    }

    func update(_ dt: TimeInterval) {
        guard state == .playing else { return }
        accumulator += dt
        if accumulator >= interval {
            accumulator = 0
            step()
        }
    }

    // MARK: Commandes

    func move(_ dx: Int) {
        guard state == .playing, var p = current else { return }
        p.origin.x += dx
        if fits(p) {
            current = p
            haptic(.click)
        }
    }

    func rotate() {
        guard state == .playing, let p = current, p.shape.rotates else { return }
        var r = p
        r.cells = p.cells.map { Cell(x: -$0.y, y: $0.x) }
        for kick in [0, -1, 1, -2, 2] {          // petits décalages contre les murs
            var k = r
            k.origin.x += kick
            if fits(k) {
                current = k
                haptic(.directionUp)
                return
            }
        }
    }

    func hardDrop() {
        guard state == .playing, var p = current else { return }
        var dropped = 0
        while true {
            var n = p
            n.origin.y += 1
            if fits(n) { p = n; dropped += 1 } else { break }
        }
        current = p
        score += dropped * 2
        lock()
    }

    // MARK: Logique interne

    private func step() {
        guard var p = current else { return }
        p.origin.y += 1
        if fits(p) { current = p } else { lock() }
    }

    private func fits(_ p: Piece) -> Bool {
        p.blocks.allSatisfy { c in
            c.x >= 0 && c.x < Grid.cols && c.y < Grid.rows &&
            (c.y < 0 || board[c.y][c.x] == nil)
        }
    }

    private func lock() {
        guard let p = current else { return }
        for c in p.blocks where c.y >= 0 {
            board[c.y][c.x] = p.shape.color
        }
        if p.blocks.contains(where: { $0.y < 0 }) {
            gameOver()
            return
        }

        let full = board.indices.filter { r in board[r].allSatisfy { $0 != nil } }
        if !full.isEmpty {
            var kept = board.enumerated()
                .filter { !full.contains($0.offset) }
                .map { $0.element }
            kept.insert(contentsOf: Array(repeating: Array(repeating: nil, count: Grid.cols),
                                          count: full.count), at: 0)
            board = kept
            lines += full.count
            score += [0, 100, 300, 500, 800][min(full.count, 4)] * level
            haptic(.success)
        }
        spawn()
    }

    private func spawn() {
        let shape = next
        next = Shapes.random()
        let piece = Piece(shape: shape, cells: shape.cells, origin: Cell(x: Grid.cols / 2, y: 0))
        current = piece
        if !fits(piece) { gameOver() }
    }

    private func gameOver() {
        state = .over
        haptic(.failure)
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "crownDrop.best")
        }
    }

    private func haptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    private static func emptyBoard() -> [[Color?]] {
        Array(repeating: Array(repeating: nil, count: Grid.cols), count: Grid.rows)
    }
}
