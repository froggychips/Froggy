import XCTest

/// Проверяет, что `default.metallib` сгенерирован и не повреждён.
/// Закрывает регрессию ADR 0013: без metallib FroggyMLXWorker умирает
/// на первой реальной MLX-операции с «Failed to load default metallib».
///
/// Тест проверяет файл в source-tree (`Sources/FroggyMLXWorker/Resources/`),
/// а не в built-bundle, потому что:
///   * SwiftPM не позволит даже распарсить `Package.swift` без файла
///     по объявленному `resources:` пути — то есть отсутствие в source-tree
///     ловится ещё на `swift build`. Этот тест добавляет проверку
///     **минимального размера**, что ловит коррупцию (например, частично
///     записанный файл при прерванной сборке).
///   * Тестовый таргет — это `.xctest` бандл; навигация к sibling'овому
///     `FroggyMLXWorker_FroggyMLXWorker.bundle` через relative paths хрупка
///     (зависит от build configuration). Source-tree путь стабилен.
final class MLXWorkerMetallibPresenceTests: XCTestCase {

    func testMetallibExistsInSourceTree() throws {
        let url = Self.metallibURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            """
            default.metallib не найден по пути \(url.path).

            Запустите `make build` (или явно `scripts/compile-metallib.sh`)
            чтобы скомпилировать metallib из mlx-swift checkout'а перед
            `swift build`/`swift test`.

            Без этого файла FroggyMLXWorker не может загрузить ни одну
            MLX-модель — см. docs/adr/0013-metallib-missing-in-swiftpm-release.md.
            """
        )
    }

    func testMetallibSizeIsReasonable() throws {
        let url = Self.metallibURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Первый тест уже покажет понятную ошибку; здесь — пропустить
            // чтобы не дублировать.
            throw XCTSkip("metallib отсутствует — см. testMetallibExistsInSourceTree")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        // Реальный metallib для mlx-swift 0.31.x ~3.1 MB. Падение
        // ниже 100 KB означает либо линковку без kernel'ов, либо
        // прерванную запись.
        XCTAssertGreaterThan(
            size,
            100_000,
            "metallib подозрительно маленький (\(size) байт). Перегенерируйте: scripts/compile-metallib.sh"
        )
    }

    /// Source-tree путь к metallib. Вычисляется относительно `#filePath`
    /// этого тест-файла, чтобы быть независимым от build configuration
    /// или working directory.
    private static var metallibURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/MLXWorkerMetallibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo root>
            .appendingPathComponent("Sources/FroggyMLXWorker/Resources/default.metallib")
    }
}
