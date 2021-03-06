//
//  syncronizer.swift
//  certificate-sync
//
//  Created by Rick Mark on 11/22/18.
//  Copyright © 2018 Dropbox. All rights reserved.
//

import Foundation

class Syncronizer {
    let requiredAuthorization = [ kSecACLAuthorizationSign,
                                  kSecACLAuthorizationMAC,
                                  kSecACLAuthorizationDerive,
                                  kSecACLAuthorizationDecrypt ]
    
    let configuration: Configuration
    
    var keychains: [ String : SecKeychain ]?
    
    init(configuration: Configuration) {
        self.configuration = configuration
    }
    
    func run() {
        let identities = mapIdentities()
        
        for (item, identity) in identities {
            if item.claimOwner {
                ensureSelfInOwnerACL(identity: identity)
            }
        }
        
        ensureACLContainsApps(aclName: configuration.aclName, items: identities)
        
        exportKeychainItems(items: identities)
        
        importKeychainItems(items: configuration.imports)
    }
    
    func openKeychain(path: String, password: String?) -> SecKeychain {
        var keychain: SecKeychain?
        assert(SecKeychainOpen(path, &keychain) == kOSReturnSuccess)
        
        assert(SecKeychainOpen(path.toUnixPath(), &keychain) == kOSReturnSuccess)
        
        var keychainStatus = SecKeychainStatus()
        assert(SecKeychainGetStatus(keychain!, &keychainStatus) == kOSReturnSuccess)
        
        if ((keychainStatus & kSecUnlockStateStatus) == 0) {
            if password != nil {
                assert(SecKeychainUnlock(keychain!, UInt32(password!.count), password!, true) == kOSReturnSuccess)
            }
            else {
                assert(SecKeychainUnlock(keychain!, 0, "", false) == kOSReturnSuccess)
            }
        }
        
        assert(SecKeychainGetStatus(keychain!, &keychainStatus) == kOSReturnSuccess)
        assert((keychainStatus & kSecUnlockStateStatus > 0) && (keychainStatus & kSecReadPermStatus > 0) && (keychainStatus & kSecWritePermStatus > 0))
        
        return keychain!
    }
    
    func getKeychains() -> [ String : SecKeychain ] {
        if keychains != nil {
            return self.keychains!
        }
        
        self.keychains = [ String : SecKeychain ]()
        
        for item in configuration.existing {
            if self.keychains!.keys.contains(item.keychainPath) == false {
                self.keychains![item.keychainPath] = openKeychain(path: item.keychainPath, password: item.password)
            }
        }
        
        for item in configuration.imports {
            if self.keychains!.keys.contains(item.keychainPath) == false {
                self.keychains![item.keychainPath] = openKeychain(path: item.keychainPath, password: item.password)
            }
        }
        
        return self.keychains!
    }
    
    func mapIdentities() -> [ ( configuration: ConfigurationItem, identity: SecIdentity ) ] {
        var results = [ (ConfigurationItem, SecIdentity ) ]()
        
        for (path, keychain) in getKeychains() {
            
            let query = [kSecClass: kSecClassIdentity,
                         kSecReturnRef: true,
                         kSecMatchLimit: kSecMatchLimitAll,
                         kSecReturnAttributes: true,
                         kSecMatchSearchList: [ keychain ]
                ] as CFDictionary
            
            var items: CFTypeRef?
            
            assert(SecItemCopyMatching(query, &items) == kOSReturnSuccess)

            for identityItem in (items! as! [[String: Any]]) {
                let identityIssuer = identityItem[kSecAttrIssuer as String] as! NSData
                
                let configurationItems = configuration.existing.filter { (item) -> Bool in
                    return item.issuer == identityIssuer as Data
                }
                
                for configurationItem in configurationItems.filter({ (configurationItem) -> Bool in
                    configurationItem.keychainPath == path
                }) {
                    let tuple = ( configurationItem, identityItem[kSecValueRef as String] as! SecIdentity )
                    results.append(tuple)
                }
            }
        }
        
        return results
    }
    
    func trustedApplicationForSelf() -> SecTrustedApplication {
        var trustedApplication: SecTrustedApplication?
        
        let createResult = SecTrustedApplicationCreateFromPath(CommandLine.arguments.first!, &trustedApplication)
        
        assert(createResult == kOSReturnSuccess)
        assert(trustedApplication != nil)
        
        return trustedApplication!
    }

    func ensureSelfInOwnerACL(identity: SecIdentity) {
        var privateKey: SecKey?
        
        assert(SecIdentityCopyPrivateKey(identity, &privateKey) == kOSReturnSuccess)
        assert(privateKey != nil)
        
        let _ = ensureSelfInKeyOwnerACL(privateKey: privateKey!)
    }
    
    func ensureSelfInKeyOwnerACL(privateKey: SecKey, saveResult: Bool = true) -> SecAccess? {
        var access: SecAccess?

        let privateKeyItem = (privateKey as Any) as! SecKeychainItem
        
        assert(SecKeychainItemCopyAccess(privateKeyItem, &access) == kOSReturnSuccess)
        assert(access != nil)

        
        let selfTrustedApplication = trustedApplicationForSelf()
        
        let aclResults = SecAccessCopyMatchingACLList(access!, kSecACLAuthorizationChangeACL)
        
        let acls = aclResults as! [ SecACL ]
        
        for acl in acls {
            var applicationList: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            
            assert(SecACLCopyContents(acl, &applicationList, &description, &promptSelector) == kOSReturnSuccess)
            
            if description == nil {
                description = "" as CFString
            }

            applicationList = updateApplicationList(existing: applicationList, applications: [ selfTrustedApplication ])
            
            assert(SecACLSetContents(acl, applicationList! as CFArray, description!, promptSelector) == kOSReturnSuccess)

            if saveResult == true {
                let setAccessResult = SecKeychainItemSetAccess(privateKeyItem, access!)
                assert(setAccessResult == kOSReturnSuccess)
            }
            return access
        }
    
        return nil
    }
    
    private func updateApplicationList(existing: CFArray?, applications: [ SecTrustedApplication ]) -> CFArray {
        var applicationListArray = existing == nil ? [ SecTrustedApplication ]() : existing as! [ SecTrustedApplication ]
        
        let existingApplicationData = applicationListArray.map { (item) -> Data in
            var data: CFData?
            
            assert(SecTrustedApplicationCopyData(item, &data) == kOSReturnSuccess)
            
            return data! as Data
        }
        
        for applicationToAdd in applications {
            var data: CFData?
            
            assert(SecTrustedApplicationCopyData(applicationToAdd, &data) == kOSReturnSuccess)
            
            let castData = data! as Data
            
            if existingApplicationData.contains(castData) == false {
                applicationListArray.append(applicationToAdd)
            }
        }
        
        return applicationListArray as CFArray
    }
    
    func ensureItemHasACL(aclName: String, identity: SecIdentity, acl: [ ACLConfigurationItem ]) {
        var privateKey: SecKey?
        
        assert(SecIdentityCopyPrivateKey(identity, &privateKey) == kOSReturnSuccess)
        assert(privateKey != nil)
        
        ensureItemKeyHasACL(aclName: aclName, privateKey: privateKey!, acl: acl)
    }
    
    func ensureItemKeyHasACL(aclName: String, privateKey: SecKey, acl: [ ACLConfigurationItem ], access existingAccess: SecAccess? = nil, saveResult: Bool = true) {

        var aclListArray: CFArray?
        var access = existingAccess
        
        let privateKeyItem = (privateKey as Any) as! SecKeychainItem
        
        if access == nil {
            assert(SecKeychainItemCopyAccess(privateKeyItem, &access) == kOSReturnSuccess)
            assert(access != nil)
        }
        
        assert(SecAccessCopyACLList(access!, &aclListArray) == kOSReturnSuccess)
        assert(aclListArray != nil)
        let acls = aclListArray as! [ SecACL ]
        
        var foundACL = false
        
        for existingACL in acls {
            var applicationListArray: CFArray?
            var descriptionString: CFString?
            var promptSelector = SecKeychainPromptSelector()
            
            assert(SecACLCopyContents(existingACL, &applicationListArray, &descriptionString, &promptSelector) == kOSReturnSuccess)
            
            let description = descriptionString as String?
            
            if description != aclName { continue }
            
            foundACL = true
            
            let applications = acl.map { (aclEntry) -> SecTrustedApplication in
                return aclEntry.trustedAppliction
            }
            
            applicationListArray = updateApplicationList(existing: applicationListArray, applications: applications)
            
            var authorizations = SecACLCopyAuthorizations(existingACL) as! [ CFString ]
            
            for authorization in requiredAuthorization {
                if authorizations.contains(authorization) == false {
                    authorizations.append(authorization)
                }
            }
            
            assert(SecACLUpdateAuthorizations(existingACL, authorizations as CFArray) == kOSReturnSuccess)
            
            assert(SecACLSetContents(existingACL, applicationListArray, description! as CFString, promptSelector) == kOSReturnSuccess)
        }
        
        if foundACL == false {
            var newACL: SecACL?
            let promptSelector = SecKeychainPromptSelector()
            
            let applications = acl.map { (item) -> SecTrustedApplication in
                item.trustedAppliction
                } as CFArray
            
            assert(SecACLCreateWithSimpleContents(access!, applications, aclName as CFString, promptSelector, &newACL) == kOSReturnSuccess)
            assert(newACL != nil)
            
            let authorizations = requiredAuthorization as CFArray
            
            assert(SecACLUpdateAuthorizations(newACL!, authorizations) == kOSReturnSuccess)
        }
        
        if saveResult == true {
            assert(SecKeychainItemSetAccess(privateKeyItem, access!) == kOSReturnSuccess)
        }
    }
    
    func ensureACLContainsApps(aclName: String, items: [ ( configuration: ConfigurationItem, identity: SecIdentity ) ]) {
        for item in items {
            ensureItemHasACL(aclName: aclName, identity: item.identity, acl: item.configuration.acls)
        }
    }
    
    func importKeychainItems(items: [ ImportItem ]) {
        for importItem in items {
            
            let keychain = getKeychains()[importItem.keychainPath]
            let path = importItem.path.absoluteString.toUnixPath()
            
            let data = NSData.init(contentsOf: importItem.path)
            var externalFormat = SecExternalFormat.formatUnknown
            var itemType = SecExternalItemType.itemTypeUnknown
            let importFlags = SecItemImportExportFlags()
            
            var importParameters = SecItemImportExportKeyParameters()

            var resultItems: CFArray? = NSMutableArray()
            
            let result = SecItemImport(data!, path as CFString, &externalFormat, &itemType, importFlags, &importParameters, nil, &resultItems)
            assert(result == kOSReturnSuccess || result == errSecDuplicateItem)
            
            for importedItem in resultItems as! [ SecKeychainItem ] {
                var access: SecAccess?
                
                if CFGetTypeID(importedItem) == SecKeyGetTypeID() {
                    let key = (importedItem as Any) as! SecKey
                    
                    
                    if importItem.claimOwner {
                        access = ensureSelfInKeyOwnerACL(privateKey: key, saveResult: false)
                    }
                    
                    ensureItemKeyHasACL(aclName: configuration.aclName, privateKey: key, acl: importItem.acls, access: access, saveResult: false)
                }
                
                var itemClass: CFString?
                switch CFGetTypeID(importedItem) {
                case SecKeyGetTypeID():
                    itemClass = kSecClassKey
                    break
                case SecCertificateGetTypeID():
                    itemClass = kSecClassCertificate
                    break
                default:
                    assert(false, "Unsupported import item classs")
                }
                
                var importQuery: [ String : Any ] = [
                    kSecClassKey as String: itemClass!,
                    kSecValueRef as String: importedItem,
                    kSecUseKeychain as String: keychain!
                ]
                
                if access != nil {
                    importQuery[kSecAttrAccess as String] = access!
                }
                if importItem.label != nil {
                    importQuery[kSecAttrLabel as String] = importItem.label!
                }
                
                var addReturnValue: CFTypeRef?
                
                let addResult = SecItemAdd(importQuery as CFDictionary, &addReturnValue)
                assert(addResult == kOSReturnSuccess || addResult == errSecDuplicateItem)
            }
        }
    }
    
    func exportKeychainItems(items: [ ( configuration: ConfigurationItem, identity: SecIdentity ) ]) {
        for item in items {
            for export in item.configuration.exports {
                var exportParameters = SecItemImportExportKeyParameters.init()
                let exportFlags = export.pemEncode ? SecItemImportExportFlags.pemArmour : SecItemImportExportFlags()
                
                var exportData: CFData?
                
                if export.password != nil {
                    let passwordData = Unmanaged<CFTypeRef>.passRetained(export.password! as CFTypeRef)
                    exportParameters.passphrase = passwordData
                }
                
                if export.format == .formatPEMSequence {
                    var privateKey: SecKey?
                    
                    assert(SecIdentityCopyPrivateKey(item.identity, &privateKey) == kOSReturnSuccess)
                    let result = SecItemExport(privateKey!, export.format, exportFlags, &exportParameters, &exportData)
                    assert(result == kOSReturnSuccess)
                }
                if export.format == .formatX509Cert {
                    var certificate: SecCertificate?
                    
                    assert(SecIdentityCopyCertificate(item.identity, &certificate) == kOSReturnSuccess)
                    let result = SecItemExport(certificate!, export.format, exportFlags, &exportParameters, &exportData)
                    assert(result == kOSReturnSuccess)
                }
                
                let exportedData = exportData as NSData?
                exportedData!.write(to: export.path, atomically: true)
                
                // TODO: Set owner
                // TODO: Set mode
            }
        }
    }
}
