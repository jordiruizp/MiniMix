// Core/Models/ModelValidation.swift — validación y normalización de modelos (T10).
//
// `validationIssues()` informa sin modificar; `normalized()` devuelve una copia
// reparada (rellena duraciones de imagen/color, limita rangos). Ninguna de las dos
// cambia la forma almacenada ni el Codable de los tipos del contrato.

import Foundation

/// Rangos válidos de los modelos (plan, secciones 6.2 y 8.5).
public enum ModelLimits {
    /// Fundido entre items de playlist, en segundos.
    public static let itemFade: ClosedRange<Double> = 0...2
    /// Fundido del switcher (`Command.fade`, `Project.defaultFadeDuration`), en segundos.
    public static let switcherFade: ClosedRange<Double> = 0.1...5
    /// Ganancia lineal de entradas y Master (1 = 0 dB).
    public static let volume: ClosedRange<Float> = 0...2
}

/// Problema detectado por la validación.
public enum ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    /// Imagen/color de playlist sin duración (se usará `PlaylistItem.defaultStillDuration`).
    case missingStillDuration(ItemID)
    /// Duración ≤ 0 o no finita.
    case invalidItemDuration(ItemID, Double)
    case invalidItemTrim(ItemID, inPoint: Double?, outPoint: Double?)
    case invalidInputTrim(InputID, inPoint: Double?, outPoint: Double?)
    case itemFadeOutOfRange(Double)
    case switcherFadeOutOfRange(Double)
    /// `input == nil` → volumen Master.
    case volumeOutOfRange(InputID?, Float)
    case duplicateInputID(InputID)
    /// Preview/Programa apunta a una entrada que no existe.
    case unknownBusInput(InputID)

    public var description: String {
        switch self {
        case .missingStillDuration(let id): "Item \(id): imagen/color sin duración"
        case let .invalidItemDuration(id, value): "Item \(id): duración inválida \(value)"
        case let .invalidItemTrim(id, inPoint, outPoint):
            "Item \(id): recorte inválido \(String(describing: inPoint))–\(String(describing: outPoint))"
        case let .invalidInputTrim(id, inPoint, outPoint):
            "Entrada \(id): recorte inválido \(String(describing: inPoint))–\(String(describing: outPoint))"
        case .itemFadeOutOfRange(let value): "Fundido de item \(value) s fuera de 0…2 s"
        case .switcherFadeOutOfRange(let value): "Fundido del switcher \(value) s fuera de 0,1…5 s"
        case let .volumeOutOfRange(id, value): "Volumen \(value) fuera de 0…2 (\(id.map(\.description) ?? "Master"))"
        case .duplicateInputID(let id): "Id de entrada duplicado \(id)"
        case .unknownBusInput(let id): "Bus apunta a entrada inexistente \(id)"
        }
    }
}

/// Error lanzado por `validate()`.
public struct ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    public let issues: [ValidationIssue]
    public init(issues: [ValidationIssue]) { self.issues = issues }
    public var description: String { issues.map(\.description).joined(separator: "; ") }
}

// MARK: - Helpers

func clamped<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
}

private func trimIsValid(inPoint: Double?, outPoint: Double?) -> Bool {
    if let inPoint, !(inPoint.isFinite && inPoint >= 0) { return false }
    if let outPoint, !(outPoint.isFinite && outPoint > 0) { return false }
    if let inPoint, let outPoint, outPoint <= inPoint { return false }
    return true
}

private func volumeIsValid(_ volume: Float) -> Bool {
    volume.isFinite && ModelLimits.volume.contains(volume)
}

private func clampedVolume(_ volume: Float) -> Float {
    volume.isFinite ? clamped(volume, to: ModelLimits.volume) : 1
}

// MARK: - PlaylistItem

extension ItemSource {
    /// Imagen o color: necesita duración explícita.
    public var isStill: Bool {
        switch self {
        case .image, .color: true
        case .video, .audio: false
        }
    }
}

extension PlaylistItem {
    /// Duración efectiva para la programación: imagen/color sin duración → `defaultStillDuration`;
    /// vídeo/audio sin duración → nil (duración del archivo).
    public var effectiveDuration: Double? {
        if let duration { return duration }
        return source.isStill ? Self.defaultStillDuration : nil
    }

    public func validationIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let duration {
            if !(duration.isFinite && duration > 0) { issues.append(.invalidItemDuration(id, duration)) }
        } else if source.isStill {
            issues.append(.missingStillDuration(id))
        }
        if !trimIsValid(inPoint: inPoint, outPoint: outPoint) {
            issues.append(.invalidItemTrim(id, inPoint: inPoint, outPoint: outPoint))
        }
        return issues
    }

    /// Copia reparada: duración de imagen/color rellenada (o sustituida si es inválida) con
    /// `defaultStillDuration`; duración inválida de vídeo/audio → nil; recorte inválido → sin recorte.
    public func normalized() -> PlaylistItem {
        var item = self
        if let duration, !(duration.isFinite && duration > 0) { item.duration = nil }
        if item.duration == nil, source.isStill { item.duration = Self.defaultStillDuration }
        if !trimIsValid(inPoint: inPoint, outPoint: outPoint) {
            item.inPoint = nil
            item.outPoint = nil
        }
        return item
    }
}

// MARK: - Playlist

extension ItemTransition {
    public func normalized() -> ItemTransition {
        guard case .fade(let seconds) = self else { return self }
        guard seconds.isFinite else { return .cut }
        let value = clamped(seconds, to: ModelLimits.itemFade)
        return value == 0 ? .cut : .fade(seconds: value)
    }
}

extension Playlist {
    public func validationIssues() -> [ValidationIssue] {
        var issues = items.flatMap { $0.validationIssues() }
        if case .fade(let seconds) = itemTransition, !(seconds.isFinite && ModelLimits.itemFade.contains(seconds)) {
            issues.append(.itemFadeOutOfRange(seconds))
        }
        return issues
    }

    public func normalized() -> Playlist {
        var playlist = self
        playlist.items = items.map { $0.normalized() }
        playlist.itemTransition = itemTransition.normalized()
        return playlist
    }
}

// MARK: - InputDescriptor

extension InputDescriptor {
    public func validationIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !trimIsValid(inPoint: inPoint, outPoint: outPoint) {
            issues.append(.invalidInputTrim(id, inPoint: inPoint, outPoint: outPoint))
        }
        if !volumeIsValid(volume) { issues.append(.volumeOutOfRange(id, volume)) }
        if case .playlist(let playlist) = content { issues += playlist.validationIssues() }
        return issues
    }

    public func normalized() -> InputDescriptor {
        var input = self
        if !trimIsValid(inPoint: inPoint, outPoint: outPoint) {
            input.inPoint = nil
            input.outPoint = nil
        }
        input.volume = clampedVolume(volume)
        if case .playlist(let playlist) = content { input.content = .playlist(playlist.normalized()) }
        return input
    }
}

// MARK: - Project

extension Project {
    /// Todos los problemas del proyecto, en orden de aparición.
    public func validationIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seen = Set<InputID>()
        for input in inputs {
            if !seen.insert(input.id).inserted { issues.append(.duplicateInputID(input.id)) }
            issues += input.validationIssues()
        }
        for bus in [preview, program].compactMap({ $0 }) where !seen.contains(bus) {
            issues.append(.unknownBusInput(bus))
        }
        if !(defaultFadeDuration.isFinite && ModelLimits.switcherFade.contains(defaultFadeDuration)) {
            issues.append(.switcherFadeOutOfRange(defaultFadeDuration))
        }
        if !volumeIsValid(masterVolume) { issues.append(.volumeOutOfRange(nil, masterVolume)) }
        return issues
    }

    /// Lanza `ValidationError` si hay algún problema.
    public func validate() throws(ValidationError) {
        let issues = validationIssues()
        if !issues.isEmpty { throw ValidationError(issues: issues) }
    }

    /// Copia reparada: normaliza entradas, limita fundido y volumen Master, y quita de los buses
    /// los ids inexistentes. Las entradas con id duplicado se conservan (solo se informan).
    public func normalized() -> Project {
        var project = self
        project.inputs = inputs.map { $0.normalized() }
        let ids = Set(inputs.map(\.id))
        if let preview, !ids.contains(preview) { project.preview = nil }
        if let program, !ids.contains(program) { project.program = nil }
        project.defaultFadeDuration = defaultFadeDuration.isFinite
            ? clamped(defaultFadeDuration, to: ModelLimits.switcherFade) : 1
        project.masterVolume = clampedVolume(masterVolume)
        return project
    }
}
