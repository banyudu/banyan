import Foundation
import Testing
@testable import BanyanCore

@Test func conversationWindowDigestMatchesSHA256Vectors() {
    let vectors: [(Data, String)] = [
        (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (Data(repeating: 0x61, count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    ]
    for (data, expected) in vectors {
        let portable = ConversationWindowDigest.portable(data).map { String(format: "%02x", $0) }.joined()
        #expect(portable == expected)
        #expect(ConversationWindowDigest.hex(data) == expected)
    }
}
