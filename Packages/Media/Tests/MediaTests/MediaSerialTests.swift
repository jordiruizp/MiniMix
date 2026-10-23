import Testing

/// Raíz serializada de las suites que usan decodificadores, audio o medidas de
/// tiempo/CPU: en paralelo se estorbarían (8 decodificadores 1080p de una suite
/// falsean los drops, la deriva y la CPU de otra). Las suites puras (FrameGrid)
/// quedan fuera y corren en paralelo.
@Suite(.serialized) enum MediaSerialTests {}
