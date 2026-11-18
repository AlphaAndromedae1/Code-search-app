import Foundation
import Security

/// Trust for Natural Resources Canada's fuel price servers on iPhones that don't have the root they need.
///
/// NRCan (www2.nrcan.gc.ca / www2.nrcan-rncan.gc.ca) sends its certificate and Entrust's issuing certificate
/// ("Entrust OV TLS Issuing RSA CA 2"), which chains to "Sectigo Public Server Authentication Root R46".
/// Some iPhones don't have that root, so Safari warns "This Connection Is Not Private" and apps can't connect.
/// For these hosts only, when the normal check fails, the connection is checked again with Sectigo R46 added
/// as a trusted root: the certificate must still be valid, unexpired, for the right host name and signed
/// through that root. Every other site gets the system's normal checks.
final class NRCanTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let hosts = ["nrcan.gc.ca", "nrcan-rncan.gc.ca"]

    /// Sectigo Public Server Authentication Root R46 (valid to 2046),
    /// SHA-256 7B:B6:47:A6:2A:EE:AC:88:BF:25:7A:A5:22:D0:1F:FE:A3:95:E0:AB:45:C7:3F:93:F6:56:54:EC:38:F2:5A:06.
    static let sectigoR46: SecCertificate? = {
        let base64 = [
        "MIIFijCCA3KgAwIBAgIQdY39i658BwD6qSWn4cetFDANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP",
        "U2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYw",
        "HhcNMjEwMzIyMDAwMDAwWhcNNDYwMzIxMjM1OTU5WjBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk",
        "MTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEB",
        "AQUAA4ICDwAwggIKAoICAQCTvtU2UnXYASOgHEdCSe5jtrch/cSV1UgrJnwUUxDaef0rty2k1Cz66jLdScK5vQ9IPXtamFSv",
        "nl0xdE8H/FAh3aTPaE8bEmNtJZlMKpnzSDBh+oF8HqcIStw+KxwfGExxqjWMrfhu6DtK2eWUAtaJhBOqbchPM8xQljeSM9xf",
        "iOefVNlI8JhD1mb9nxc4Q8UBUQvX4yMPFF1bFOdLvt30yNoDN9HWOaEhUTCDsG3XME6WW5HwcCSrv0WBZEMNvSE6Lzzpng3L",
        "ILVCJ8zab5vuZDCQOc2TZYEhMbUjUDM3IuM47fgxMMxF/mL50V0yeUKH32rMVhlATc6qu/m1dkmU8Sf4kaWD5QazYw6A3OAS",
        "VYCmO2a0OYctyPDQ0RTp5A1NDvZdV3LFOxxHVp3i1fuBYYzMTYCQNFu31xR13NgESJ/AwSiItOkcyqex8Va3e0lMWeUgFaiE",
        "Ain6OJRpmkkGj80feRQXEgyDet4fsZfu+Zd4KKTIRJLpfSYFplhym3kT2BFfrsU4YjRosoYwjviQYZ4ybPUHNs2iTG7sijbt",
        "8uaZFURww3y8nDnAtOFr94MlI1fZEoDlSfB1D++N6xybVCi0ITz8fAr/73trdf+LHaAZBav6+CuBQug4urv7qv094PPK306X",
        "lynt8xhW6aWWrL3DkJiy4Pmi1KZHQ3xtzwIDAQABo0IwQDAdBgNVHQ4EFgQUVnNYZJX5khqwEioEYnmhQBWIIUkwDgYDVR0P",
        "AQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAC9cmTz8Bl6MlC5w6tIyMY208FHVvArzZJ8H",
        "XtXBc2hkeqK5Duj5XYUtqDdFqij0lgVQYKlJfp/imTYpE0RHap1VIDzYm/EDMrraQKFz6oOht0SmDpkBm+S8f74TlH7Kph52",
        "gDY9hAaLMyZlbcp+nv4fjFg4exqDsQ+8FxG75gbMY/qB8oFM2gsQa6H61SilzwZAFv97fRheORKkU55+MkIQpiGRqRxOF3yE",
        "vJ+M0ejf5lG5Nkc/kLnHvALcWxxPDkjBJYOcCj+esQMzEhonrPcibCTRAUH4WAP+JWgiH5paPHxsnnVI84HxZmduTILA7rpX",
        "DhjvLpr3Etiga+kFpaHpaPi8TD8SHkXoUsCjvxInebnMMTzD9joiFgOgyY9mpFuiTdaBJQbpdqQACj7LzTWb4OE4y2BThihC",
        "QRxEV+ioratF4yUQvNs+ZUH7G6aXD+u5dHn5HrwdVw1Hr8Mvn4dGp+smWg9WY7ViYG4A++MnESLn/pmPNPW56MORcr3Ywx65",
        "LvKRRFHQV80MNNVIIb/bE/FmJUNS0nAiNs2fxBx1IK1jcmMGDw4nztJqDby1ORrp0XZ60Vzk50lJLVU3aPAaOpg+VBeHVOmm",
        "J1CJeyAvP/+/oYtKR5j/K3tJPsMpRmAYQqszKbrAKbkTidOIijlBO8n9pu0f9GBj39ItVQGL",
        ].joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }()

    /// Debug/CI only: check with Sectigo R46 alone (as an iPhone without the root would need), even if the
    /// system trusts the server, to prove the fallback works.
    let anchorOnlyForTesting: Bool

    init(anchorOnlyForTesting: Bool = false) {
        self.anchorOnlyForTesting = anchorOnlyForTesting
    }

    static func isNRCan(_ host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        guard Self.isNRCan(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if !anchorOnlyForTesting, SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if Self.evaluateWithSectigoR46(trust, host: host, only: anchorOnlyForTesting) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func evaluateWithSectigoR46(_ trust: SecTrust, host: String, only: Bool) -> Bool {
        guard let root = sectigoR46 else { return false }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, only)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
