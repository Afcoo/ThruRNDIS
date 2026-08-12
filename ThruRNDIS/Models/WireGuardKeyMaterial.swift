/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

struct WireGuardKeyMaterial: Equatable {
    let serverPrivateKey: Data
    let serverPublicKey: Data
    let clientPrivateKey: Data
    let clientPublicKey: Data
}
