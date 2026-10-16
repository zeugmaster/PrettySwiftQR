import Foundation
@testable import PrettyQRCore

func makeMessage(len: Int, seed: String = "Wolf") -> Data {
    let rng = Xoshiro256(string: seed)
    return rng.nextData(count: len)
}

func makeMessageUR(len: Int, seed: String = "Wolf") -> UR {
    UR(bytes: makeMessage(len: len, seed: seed))
}
