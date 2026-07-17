/*
Copyright (C) 2026 Afcoo.
*/

struct WireGuardKeyMaterial: Equatable {
    let serverPrivateKey: String
    let serverPublicKey: String
    let clientPrivateKey: String
    let clientPublicKey: String
}
