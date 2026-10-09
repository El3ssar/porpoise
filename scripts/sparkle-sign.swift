// Sparkle's EdDSA (Ed25519) update signatures, without Sparkle's own tools.
//   swift scripts/sparkle-sign.swift generate <private-key-file>   creates a key, prints the public key (SUPublicEDKey)
//   swift scripts/sparkle-sign.swift public <private-key-file>     prints the public key again
//   swift scripts/sparkle-sign.swift sign <private-key-file> <file>   prints the signature for the appcast
//   swift scripts/sparkle-sign.swift verify <public-key> <signature> <file>
// The private key file holds the base64 of the 32-byte key; keep it in .signing/ (git-ignored) and in the
// SPARKLE_ED_PRIVATE_KEY secret. Losing it means existing installs can't verify (and won't install) new updates.
import CryptoKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func readKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("can't read the key in \(path)") }
    return key
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "generate" where args.count == 3:
    guard !FileManager.default.fileExists(atPath: args[2]) else { fail("\(args[2]) exists; not overwriting a key") }
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: args[2], contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public" where args.count == 3:
    print(readKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 4:
    guard let data = FileManager.default.contents(atPath: args[3]) else { fail("can't read \(args[3])") }
    print(try! readKey(args[2]).signature(for: data).base64EncodedString())
case "verify" where args.count == 5:
    guard let pub = Data(base64Encoded: args[2]).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
          let sig = Data(base64Encoded: args[3]), let data = FileManager.default.contents(atPath: args[4]) else { fail("bad input") }
    if pub.isValidSignature(sig, for: data) { print("valid") } else { fail("INVALID") }
default:
    fail("usage: sparkle-sign.swift generate|public|sign|verify …")
}
