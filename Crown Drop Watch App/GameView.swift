import SwiftUI
import Combine

// MARK: - Textes FR / EN
// Langue choisie avec les drapeaux (mémorisée), sinon langue de la montre.

enum L {
    static let key = "crownDrop.lang"
    static var fr: Bool {
        if let lang = UserDefaults.standard.string(forKey: key), !lang.isEmpty { return lang == "fr" }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("fr")
    }
    static func t(_ fr: String, _ en: String) -> String { L.fr ? fr : en }

    static var move:      String { t("Couronne : déplacer", "Crown: move") }
    static var rotate:    String { t("Tap : tourner", "Tap: rotate") }
    static var drop:      String { t("Glisser ↓ : chute", "Swipe ↓: drop") }
    static var longPause: String { t("Appui long : pause", "Long press: pause") }
    static var tapPlay:   String { t("Touchez pour jouer", "Tap to play") }
    static var pause:     String { "Pause" }
    static var tapResume: String { t("Touchez pour reprendre", "Tap to resume") }
    static var gameOver:  String { t("Fin de partie", "Game over") }
    static var record:    String { t("Record", "Best") }
    static var tapReplay: String { t("Touchez pour rejouer", "Tap to play again") }
    static var score:     String { "SCORE" }
    static var level:     String { t("NIV.", "LVL") }
    static var next:      String { t("SUIV.", "NEXT") }
    static var restart:   String { t("Recommencer", "Restart") }
}

/// Un seul drapeau : affiche la langue active, un tap bascule FR ⇄ EN.
struct LangToggle: View {
    @AppStorage(L.key) private var lang = ""

    var body: some View {
        // Lire `lang` ici garantit que SwiftUI redessine le drapeau au tap.
        let isFR = lang.isEmpty ? L.fr : lang == "fr"
        Button { lang = isFR ? "en" : "fr" } label: {
            Text(isFR ? "🇫🇷" : "🇬🇧")
                .font(.system(size: 20))
                .frame(width: 36, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFR ? "Français, toucher pour passer en anglais"
                                 : "English, tap to switch to French")
    }
}

struct GameView: View {
    @StateObject private var game = Game()
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    @State private var lastTick = Date()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L.key) private var lang = ""   // redessine l'écran au changement de langue

    /// Réglage de la sensibilité de la couronne (1.0 = nerveux, 3.0 = très doux).
    private let crownStep = 2.0

    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let cell = floor(min((geo.size.width - 46) / CGFloat(Grid.cols),
                                 geo.size.height / CGFloat(Grid.rows)))
            HStack(alignment: .top, spacing: 6) {
                BoardView(game: game, cell: cell)
                    .frame(width: cell * CGFloat(Grid.cols), height: cell * CGFloat(Grid.rows))
                SidePanel(game: game)
                    .id("panel-\(lang)")      // force la mise à jour des textes
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { overlay.id("overlay-\(lang)") }
        }
        .background(Palette.ink.ignoresSafeArea())
        .focusable()
        .digitalCrownRotation($crown, from: -100_000, through: 100_000, by: 1,
                              sensitivity: .low, isContinuous: true,
                              isHapticFeedbackEnabled: false)
        .onChange(of: crown) { _, value in
            // Plus crownStep est grand, plus il faut tourner pour avancer d'une case.
            let steps = Int(((value - lastCrown) / crownStep).rounded(.towardZero))
            guard steps != 0 else { return }
            lastCrown += Double(steps) * crownStep
            // Une case maximum par événement : évite les sauts de plusieurs colonnes.
            game.move(steps > 0 ? 1 : -1)
        }
        .onLongPressGesture(minimumDuration: 0.6) {
            game.state == .playing ? game.pause() : game.resume()
        }
        .onTapGesture { handleTap() }
        .gesture(
            DragGesture(minimumDistance: 15).onEnded { v in
                if v.translation.height > 20 { game.hardDrop() }
            }
        )
        .onReceive(timer) { now in
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            game.update(min(dt, 0.1))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: game.reset()   // sortie par la couronne : retour à l'accueil
            case .inactive:   game.pause()   // poignet baissé : simple pause
            default:          break
            }
        }
    }

    private func handleTap() {
        switch game.state {
        case .ready, .over: game.start()
        case .paused:       game.resume()
        case .playing:      game.rotate()
        }
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .ready:
            OverlayCard(title: "Crown Drop",
                        lines: [L.move, L.rotate, L.drop, L.longPause],
                        footer: L.tapPlay, showLang: true)
        case .paused:
            OverlayCard(title: L.pause, lines: [], footer: L.tapResume, showLang: true)
        case .over:
            OverlayCard(title: L.gameOver,
                        lines: ["Score \(game.score)", "\(L.record) \(game.best)"],
                        footer: L.tapReplay)
        case .playing:
            EmptyView()
        }
    }
}

// MARK: - Plateau

struct BoardView: View {
    @ObservedObject var game: Game
    let cell: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for r in 0..<Grid.rows {
                for c in 0..<Grid.cols {
                    ctx.fill(block(c, r), with: .color(game.board[r][c] ?? Palette.empty))
                }
            }
            if game.state == .playing, let g = game.ghost {
                for b in g.blocks where b.y >= 0 {
                    ctx.stroke(block(b.x, b.y), with: .color(g.shape.color.opacity(0.5)), lineWidth: 1)
                }
            }
            if let p = game.current {
                for b in p.blocks where b.y >= 0 {
                    ctx.fill(block(b.x, b.y), with: .color(p.shape.color))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.gold.opacity(0.35), lineWidth: 1))
    }

    private func block(_ x: Int, _ y: Int) -> Path {
        let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
            .insetBy(dx: 0.75, dy: 0.75)
        return Path(roundedRect: rect, cornerRadius: cell * 0.2)
    }
}

// MARK: - Panneau latéral

struct SidePanel: View {
    @ObservedObject var game: Game
    @AppStorage(L.key) private var lang = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            caption(L.score)
            value("\(game.score)")
            caption(L.level)
            value("\(game.level)")
            caption(L.next)
            NextPreview(shape: game.next)
            if game.state == .playing {
                VStack(spacing: 5) {
                    iconButton("pause.fill", label: L.pause) { game.pause() }
                    iconButton("arrow.counterclockwise", label: L.restart) { game.start() }
                }
                .padding(.top, 4)
            }
        }
        .frame(width: 40, alignment: .leading)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.gold)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.gold.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.gold.opacity(0.8))
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 14, weight: .semibold, design: .serif))
            .foregroundStyle(Palette.parchment)
            .minimumScaleFactor(0.5).lineLimit(1)
    }
}

struct NextPreview: View {
    let shape: Shape
    private let cell: CGFloat = 8

    var body: some View {
        let minX = shape.cells.map(\.x).min() ?? 0
        let minY = shape.cells.map(\.y).min() ?? 0
        Canvas { ctx, _ in
            for c in shape.cells {
                let rect = CGRect(x: CGFloat(c.x - minX) * cell, y: CGFloat(c.y - minY) * cell,
                                  width: cell, height: cell).insetBy(dx: 0.5, dy: 0.5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(shape.color))
            }
        }
        .frame(width: cell * 3, height: cell * 3)
    }
}

// MARK: - Écrans d'état

struct OverlayCard: View {
    let title: String
    let lines: [String]
    let footer: String
    var showLang = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Palette.gold)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.parchment)
            }
            Text(footer)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.gold.opacity(0.7))
                .padding(.top, 4)
            if showLang {
                LangToggle().padding(.top, 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ink.opacity(0.88))
    }
}
