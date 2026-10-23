import Metal

/// Reutiliza texturas por (ancho, alto, formato, usage, almacenamiento).
///
/// Thread-safe con un cerrojo corto. `memoryLimit` acota los bytes que el pool
/// retiene **libres** (las texturas en uso pertenecen a quien las sacó); al
/// superarlo se liberan primero las devueltas hace más tiempo.
public final class TexturePool: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var pixelFormat: MTLPixelFormat
        public var usage: MTLTextureUsage
        public var storageMode: MTLStorageMode

        public init(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm,
                    usage: MTLTextureUsage = [.shaderRead, .renderTarget],
                    storageMode: MTLStorageMode = .private) {
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
            self.usage = usage
            self.storageMode = storageMode
        }

        init(_ texture: MTLTexture) {
            self.init(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat,
                      usage: texture.usage, storageMode: texture.storageMode)
        }

        public static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.width == rhs.width && lhs.height == rhs.height && lhs.pixelFormat == rhs.pixelFormat
                && lhs.usage.rawValue == rhs.usage.rawValue && lhs.storageMode == rhs.storageMode
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(width)
            hasher.combine(height)
            hasher.combine(pixelFormat.rawValue)
            hasher.combine(usage.rawValue)
            hasher.combine(storageMode.rawValue)
        }
    }

    private struct Entry {
        let texture: MTLTexture
        let bytes: Int
        let stamp: UInt64
    }

    private struct State {
        var free: [Key: [Entry]] = [:]
        var freeBytes = 0
        var memoryLimit: Int
        var clock: UInt64 = 0
    }

    public let device: MTLDevice
    private let state: UnfairLocked<State>

    /// - Parameter memoryLimit: bytes máximos retenidos en texturas libres (por defecto 256 MB).
    public init(device: MTLDevice, memoryLimit: Int = 256 << 20) {
        self.device = device
        self.state = UnfairLocked(State(memoryLimit: max(0, memoryLimit)))
    }

    public var memoryLimit: Int {
        get { state.withLock { $0.memoryLimit } }
        set {
            state.withLock { st in
                st.memoryLimit = max(0, newValue)
                Self.trim(&st)
            }
        }
    }

    /// Bytes retenidos en texturas libres.
    public var cachedBytes: Int { state.withLock { $0.freeBytes } }

    /// Número de texturas libres retenidas.
    public var cachedCount: Int { state.withLock { $0.free.values.reduce(0) { $0 + $1.count } } }

    /// Saca una textura del pool o crea una nueva si no hay libre con esa clave.
    public func dequeue(_ key: Key) -> MTLTexture? {
        let reused: MTLTexture? = state.withLock { st in
            guard var list = st.free[key], let entry = list.popLast() else { return nil }
            st.free[key] = list.isEmpty ? nil : list
            st.freeBytes -= entry.bytes
            return entry.texture
        }
        if let reused { return reused }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat, width: key.width, height: key.height, mipmapped: false)
        desc.usage = key.usage
        desc.storageMode = key.storageMode
        return device.makeTexture(descriptor: desc)
    }

    /// Atajo de `dequeue(_:)` (por defecto BGRA8, `.shaderRead` + `.renderTarget`, `.private`).
    public func dequeue(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm,
                        usage: MTLTextureUsage = [.shaderRead, .renderTarget],
                        storageMode: MTLStorageMode = .private) -> MTLTexture? {
        dequeue(Key(width: width, height: height, pixelFormat: pixelFormat, usage: usage, storageMode: storageMode))
    }

    /// Devuelve una textura al pool. Solo si la GPU ya no la usa; si no, usar
    /// `recycle(_:after:)`.
    public func recycle(_ texture: MTLTexture) {
        let key = Key(texture)
        let bytes = texture.allocatedSize
        state.withLock { st in
            guard bytes <= st.memoryLimit else { return }
            st.clock &+= 1
            st.free[key, default: []].append(Entry(texture: texture, bytes: bytes, stamp: st.clock))
            st.freeBytes += bytes
            Self.trim(&st)
        }
    }

    /// Devuelve la textura cuando `commandBuffer` termine (llamar antes de `commit`).
    public func recycle(_ texture: MTLTexture, after commandBuffer: MTLCommandBuffer) {
        nonisolated(unsafe) let texture = texture
        commandBuffer.addCompletedHandler { [weak self] _ in self?.recycle(texture) }
    }

    /// Libera todas las texturas libres.
    public func purge() {
        state.withLock { st in
            st.free.removeAll()
            st.freeBytes = 0
        }
    }

    private static func trim(_ st: inout State) {
        while st.freeBytes > st.memoryLimit {
            var oldestStamp = UInt64.max
            var oldest: (key: Key, index: Int)?
            for (key, list) in st.free {
                for (index, entry) in list.enumerated() where entry.stamp < oldestStamp {
                    oldestStamp = entry.stamp
                    oldest = (key, index)
                }
            }
            guard let oldest, var list = st.free[oldest.key] else { break }
            let entry = list.remove(at: oldest.index)
            st.free[oldest.key] = list.isEmpty ? nil : list
            st.freeBytes -= entry.bytes
        }
    }
}
