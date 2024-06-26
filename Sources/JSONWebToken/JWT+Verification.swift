/*
 * Copyright 2024 Gonçalo Frade
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import JSONWebEncryption
import JSONWebKey
import JSONWebSignature

extension JWT {
    
    /// Verifies a JWT string and returns a decoded JWT if successful.
    ///
    /// This method supports both JWS (JSON Web Signature) and JWE (JSON Web Encryption) formats. It first determines the format of the JWT based on the number of components separated by dots in the JWT string. The method also handles nested JWTs, verifying each layer as needed.
    ///
    /// - Parameters:
    ///   - jwtString: The JWT string to be verified and decoded.
    ///   - senderKey: An optional `JWK` representing the sender's key, used for verifying a JWS.
    ///   - recipientKey: An optional `JWK` representing the recipient's key, used for decrypting a JWE.
    ///   - nestedKeys: An array of `JWK` used for verifying nested JWTs.
    ///   - expectedIssuer: An optional expected issuer (`iss` claim) to validate.
    ///   - expectedAudience: An optional expected audience (`aud` claim) to validate.
    /// - Returns: A `JWT` instance containing the payload and format.
    /// - Throws: `JWTError` if verification fails, the signature is invalid, claims validation fails, the JWT format is incorrect, or if nested JWT keys are missing.
    public static func verify(
        jwtString: String,
        senderKey: JWK? = nil,
        recipientKey: JWK? = nil,
        nestedKeys: [JWK] = [],
        expectedIssuer: String? = nil,
        expectedAudience: String? = nil
    ) throws -> JWT {
        let components = jwtString.components(separatedBy: ".")
        switch components.count {
        case 3:
            let jws = try JWS(jwsString: jwtString)
            if jws.protectedHeader.contentType == "JWT" {
                guard let key = getKeyForJWSHeader(
                    keys: nestedKeys,
                    header: jws.protectedHeader
                ) else { throw JWTError.missingNestedJWTKey }
                
                return try verify(
                    jwtString: jws.payload.tryToString(),
                    senderKey: key,
                    recipientKey: nil,
                    nestedKeys: nestedKeys,
                    expectedIssuer: expectedIssuer,
                    expectedAudience: expectedAudience
                )
            }
            let payload = try JSONDecoder().decode(C.self, from: jws.payload)
            
            guard try jws.verify(key: senderKey) else {
                throw JWTError.invalidSignature
            }
            try validateClaims(
                claims: payload,
                expectedIssuer: expectedIssuer,
                expectedAudience: expectedAudience
            )
            return .init(payload: payload, format: .jws(jws))
        case 5:
            let jwe = try JWE(compactString: jwtString)
            
            let decryptedPayload = try jwe.decrypt(
                senderKey: senderKey,
                recipientKey: recipientKey
            )
            
            if jwe.protectedHeader.contentType == "JWT" {
                guard let key = getKeyForJWEHeader(
                    keys: nestedKeys,
                    header: jwe.protectedHeader
                ) else { throw JWTError.missingNestedJWTKey }
                
                return try verify(
                    jwtString: decryptedPayload.tryToString(),
                    senderKey: senderKey,
                    recipientKey: key,
                    nestedKeys: nestedKeys,
                    expectedIssuer: expectedIssuer,
                    expectedAudience: expectedAudience
                )
            }
            let payload = try JSONDecoder().decode(C.self, from: decryptedPayload)
            return .init(payload: payload, format: .jwe(jwe))
        default:
            throw JWTError.somethingWentWrong
        }
    }
}

public func validateClaims(
    claims: JWTRegisteredFieldsClaims,
    expectedIssuer: String? = nil,
    expectedAudience: String? = nil
) throws {
    let currentDate = Date()

    // Validate Issuer
    if let expectedIssuer = expectedIssuer, let issuer = claims.issuer {
        guard issuer == expectedIssuer else {
            throw DefaultJWT.JWTError.issuerMismatch
        }
    }

    // Validate Expiration Time
    if let expirationTime = claims.expirationTime {
        guard currentDate < expirationTime else {
            throw DefaultJWT.JWTError.expired
        }
    }

    // Validate Not Before Time
    if let notBeforeTime = claims.notBeforeTime {
        guard currentDate >= notBeforeTime else {
            throw DefaultJWT.JWTError.notYetValid
        }
    }

    // Validate Issued At
    if let issuedAt = claims.issuedAt {
        guard issuedAt <= currentDate else {
            throw DefaultJWT.JWTError.issuedInTheFuture
        }
    }

    // Validate Audience
    if let expectedAudience = expectedAudience, let audience = claims.audience {
        guard audience.contains(expectedAudience) else {
            throw DefaultJWT.JWTError.audienceMismatch
        }
    }
    
    try claims.validateExtraClaims()
}

private func getKeyForJWSHeader(keys: [JWK], header: JWSRegisteredFieldsHeader?) -> JWK? {
    keys.first {
        if let thumbprint = try? $0.thumbprint() {
            if thumbprint == header?.keyID {
                return true
            }
            
            if
                let hThumbprint = try? header?.jwk?.thumbprint(),
                hThumbprint == thumbprint
            {
                return true
            }
        }
        guard let header else { return false }
        
        if let x509Url = header.x509URL, x509Url == $0.x509URL { return true }
        if
            let x509CertificateSHA256Thumbprint = header.x509CertificateSHA256Thumbprint,
            x509CertificateSHA256Thumbprint == $0.x509CertificateSHA256Thumbprint
        { return true }
        
        if
            let x509CertificateSHA1Thumbprint = header.x509CertificateSHA1Thumbprint,
            x509CertificateSHA1Thumbprint == $0.x509CertificateSHA1Thumbprint
        { return true }
        
        if let keyID = header.keyID, keyID == $0.keyID { return true }
        
        return false
    }
}

private func getKeyForJWEHeader(keys: [JWK], header: JWERegisteredFieldsHeader?) -> JWK? {
    keys.first {
        if let thumbprint = try? $0.thumbprint() {
            if thumbprint == header?.keyID {
                return true
            }
            
            if
                let hThumbprint = try? header?.jwk?.thumbprint(),
                hThumbprint == thumbprint
            {
                return true
            }
        }
        guard let header else { return false }
        
        if let x509Url = header.x509URL, x509Url == $0.x509URL { return true }
        if
            let x509CertificateSHA256Thumbprint = header.x509CertificateSHA256Thumbprint,
            x509CertificateSHA256Thumbprint == $0.x509CertificateSHA256Thumbprint
        { return true }
        
        if
            let x509CertificateSHA1Thumbprint = header.x509CertificateSHA1Thumbprint,
            x509CertificateSHA1Thumbprint == $0.x509CertificateSHA1Thumbprint
        { return true }
        
        if let keyID = header.keyID, keyID == $0.keyID { return true }
        
        return false
    }
}
