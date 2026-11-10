import Foundation

// The engine's whole interface to JavaScript: a C ABI with no dependencies.
//
// The host copies a UTF-8 JSON request (and optionally a byte payload, such as
// a file being opened) into memory it allocated with `dazzle_alloc`, then calls
// `dazzle_call`. The response is JSON, plus an optional byte payload (such as a
// file being saved), which the host reads through the `dazzle_response_*` and
// `dazzle_payload_*` accessors before making its next call.

private nonisolated(unsafe) var response = Buffer()
private nonisolated(unsafe) var payload = Buffer()

/// Memory owned by the engine that the host reads between calls.
private struct Buffer {
    var pointer: UnsafeMutableRawPointer?
    var count = 0

    mutating func replace(with bytes: some Collection<UInt8>) {
        pointer?.deallocate()
        count = bytes.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        UnsafeMutableRawBufferPointer(start: pointer, count: count).copyBytes(from: bytes)
    }
}

@_expose(wasm, "dazzle_alloc")
@_cdecl("dazzle_alloc")
public func dazzleAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 1), alignment: 8)
}

@_expose(wasm, "dazzle_free")
@_cdecl("dazzle_free")
public func dazzleFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// Handles one request. Returns 0; failures are reported inside the response.
@_expose(wasm, "dazzle_call")
@_cdecl("dazzle_call")
public func dazzleCall(
    _ request: UnsafeRawPointer, _ requestLength: Int32, _ input: UnsafeRawPointer?, _ inputLength: Int32
) -> Int32 {
    let requestData = Data(bytes: request, count: Int(requestLength))
    let inputData = input.map { Data(bytes: $0, count: Int(inputLength)) }
    // The engine runs on the one thread WebAssembly has, which is the main actor's.
    let (json, output) = MainActor.assumeIsolated { Bridge.shared.handle(requestData, payload: inputData) }
    response.replace(with: json)
    payload.replace(with: output ?? Data())
    return 0
}

@_expose(wasm, "dazzle_response_pointer")
@_cdecl("dazzle_response_pointer")
public func dazzleResponsePointer() -> UnsafeMutableRawPointer? { response.pointer }

@_expose(wasm, "dazzle_response_length")
@_cdecl("dazzle_response_length")
public func dazzleResponseLength() -> Int32 { Int32(response.count) }

@_expose(wasm, "dazzle_payload_pointer")
@_cdecl("dazzle_payload_pointer")
public func dazzlePayloadPointer() -> UnsafeMutableRawPointer? { payload.pointer }

@_expose(wasm, "dazzle_payload_length")
@_cdecl("dazzle_payload_length")
public func dazzlePayloadLength() -> Int32 { Int32(payload.count) }
