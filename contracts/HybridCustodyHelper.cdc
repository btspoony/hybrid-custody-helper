// Third-party imports
import "MetadataViews"

// HybridCustody imports
import "HybridCustody"
import "CapabilityDelegator"
import "CapabilityFactory"
import "CapabilityFilter"

/// The contract is the helper contract of HybridCustody manangement
///
pub contract HybridCustodyHelper {

    /// Ensure the manager resource exists in the account
    ///
    pub fun ensureManagerExists(
        _ managerAcct: &AuthAccount
    ) {
        post {
            managerAcct.borrow<&HybridCustody.Manager>(from: HybridCustody.ManagerStoragePath) != nil: "Failed to create manager"
            managerAcct.capabilities.get<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(HybridCustody.ManagerPublicPath) != nil: "Failed to publish mananger pub cap"
        }
        // Check if the Account Manager exists
        if managerAcct.borrow<&HybridCustody.Manager>(from: HybridCustody.ManagerStoragePath) == nil {
            // Create a new account manager
            let m <- HybridCustody.createManager(filter: nil)
            managerAcct.save(<-m, to: HybridCustody.ManagerStoragePath)
        }

        // ensure public capabilty exists
        let pubCap = managerAcct.capabilities.get<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(HybridCustody.ManagerPublicPath)
        if pubCap == nil || pubCap!.check() == false{
            // unpublish the public path
            managerAcct.capabilities.unpublish(HybridCustody.ManagerPublicPath)
            // re-publish the public path
            let hybridCustodyPubCap = managerAcct.capabilities.storage
                .issue<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(HybridCustody.ManagerStoragePath)
            managerAcct.capabilities.publish(hybridCustodyPubCap, at: HybridCustody.ManagerPublicPath)
        }
    }

    /// Issue the HybridCustody manager private capability
    ///
    pub fun issueManagerPrivateCapability(
        _ managerAcct: &AuthAccount
    ): Capability<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}> {
        post {
            result.check(): "Failed to issue a new private capability"
        }
        // issue a new private capability
        return managerAcct.capabilities.storage
            .issue<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}>(HybridCustody.ManagerStoragePath)
    }

    /// Setup the child account for the manager
    ///
    /// - managerAcct: the account of the manager
    /// - accountManager: the account manager resource reference
    /// - childAcctCap: the capability of the child account
    ///
    pub fun assignNewChild(
        _ managerAcct: &AuthAccount,
        _ childAcctCap: Capability<&AuthAccount>,
    ) {
        pre {
            childAcctCap.check(): "Child account capability is invalid"
        }
        post {
            managerAcct.borrow<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(from: HybridCustody.ManagerStoragePath)?.borrowAccountPublic(addr: childAcctCap.address) != nil: "Failed to add child account"
        }

        // Ensure the manager resource exists
        self.ensureManagerExists(managerAcct)

        let manager = managerAcct.borrow<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}>(from: HybridCustody.ManagerStoragePath)
            ?? panic("Failed to borrow hybrid custody manager.")

        let child = childAcctCap.borrow() ?? panic("Failed to borrow child account")

        // Child: createOwnedAccount
        if child.borrow<&HybridCustody.OwnedAccount>(from: HybridCustody.OwnedAccountStoragePath) == nil {
            let ownedAccount <- HybridCustody.createOwnedAccount(acct: childAcctCap)
            child.save(<-ownedAccount, to: HybridCustody.OwnedAccountStoragePath)
        }

        // publish to new public path
        child.capabilities.unpublish(HybridCustody.OwnedAccountPublicPath)
        let ownedChildCap = child.capabilities.storage
            .issue<&HybridCustody.OwnedAccount{HybridCustody.BorrowableAccount, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}>(HybridCustody.OwnedAccountStoragePath)
        child.capabilities.publish(ownedChildCap, at: HybridCustody.OwnedAccountPublicPath)

        // Child: giveOwnership
        let owned = child.borrow<&HybridCustody.OwnedAccount>(from: HybridCustody.OwnedAccountStoragePath)
            ?? panic("owned not found")
        owned.giveOwnership(to: managerAcct.address)

        // Manager: Accept OwnedAccount capablity and AddOwnedAccount
        // generate inboxName by manager address
        let inboxName = HybridCustody.getOwnerIdentifier(managerAcct.address)
        let ownedAccountCap = managerAcct.inbox
            .claim<&AnyResource{HybridCustody.OwnedAccountPrivate, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}>(inboxName, provider: child.address)
            ?? panic("owned account cap not found")

        manager.addOwnedAccount(cap: ownedAccountCap)

        // Child: publishToParent

        // Account Manager: AddAccount

    }

    /// Fetch or create a capability factory capability
    ///
    pub fun fetchOrCreateCapabilityFactory(
        _ managerAcct: &AuthAccount,
    ): Capability<&CapabilityFactory.Manager{CapabilityFactory.Getter}> {
        post {
            result.check(): "CapabilityFactory is not setup properly"
        }

        // create and save resource, if not exist
        if managerAcct.borrow<&AnyResource>(from: CapabilityFactory.StoragePath) == nil {
            managerAcct.save(<- CapabilityFactory.createFactoryManager(), to: CapabilityFactory.StoragePath)
        }

        var factoryCap = managerAcct.capabilities.get<&CapabilityFactory.Manager{CapabilityFactory.Getter}>(CapabilityFactory.PublicPath)
        if factoryCap == nil || factoryCap?.check() == false {
            managerAcct.capabilities.unpublish(CapabilityFactory.PublicPath)
            factoryCap = managerAcct.capabilities.storage
                .issue<&CapabilityFactory.Manager{CapabilityFactory.Getter}>(CapabilityFactory.StoragePath)
            managerAcct.capabilities.publish(factoryCap!, at: CapabilityFactory.PublicPath)
        }

        return factoryCap ?? panic("CapabilityFactory not found")
    }

    /// Fetch or create the allow all filter capability
    ///
    pub fun fetchOrCreateAllowAllCapabilityFilter(
        _ managerAcct: &AuthAccount,
    ): Capability<&{CapabilityFilter.Filter}> {
        post {
            result.check() == true: "CapabilityFilter is not setup properly"
            result.borrow()!.getType() == Type<@CapabilityFilter.AllowAllFilter>(): "CapabilityFilter in account is not AllowAll Filter"
        }
        return self._fetchOrCreateCapabilityFilter(managerAcct, Type<@CapabilityFilter.AllowAllFilter>())
    }

    /// Fetch or create the allow list filter capability
    ///
    pub fun fetchOrCreateAllowlistCapabilityFilter(
        _ managerAcct: &AuthAccount,
    ): Capability<&{CapabilityFilter.Filter}> {
        post {
            result.check() == true: "CapabilityFilter is not setup properly"
            result.borrow()!.getType() == Type<@CapabilityFilter.AllowlistFilter>(): "CapabilityFilter in account is not Allowlist Filter"
        }
        return self._fetchOrCreateCapabilityFilter(managerAcct, Type<@CapabilityFilter.AllowlistFilter>())
    }

    /// Fetch or create the deny list filter capability
    ///
    pub fun fetchOrCreateDenylistCapabilityFilter(
        _ managerAcct: &AuthAccount,
    ): Capability<&{CapabilityFilter.Filter}> {
        post {
            result.check() == true: "CapabilityFilter is not setup properly"
            result.borrow()!.getType() == Type<&CapabilityFilter.DenylistFilter>(): "CapabilityFilter in account is not Denylist Filter"
        }
        return self._fetchOrCreateCapabilityFilter(managerAcct, Type<@CapabilityFilter.DenylistFilter>())
    }

    // -------- Internal Methods --------

    /// Fetch or create a capability filter capability
    ///
    access(self) fun _fetchOrCreateCapabilityFilter(
        _ managerAcct: &AuthAccount,
        _ t: Type
    ): Capability<&{CapabilityFilter.Filter}> {
        post {
            result.check(): "CapabilityFilter is not setup properly"
        }

        // create and save resource, if not exist
        if managerAcct.borrow<&AnyResource>(from: CapabilityFilter.StoragePath) == nil {
            managerAcct.save(<- CapabilityFilter.create(t), to: CapabilityFilter.StoragePath)
        }

        var filterCap = managerAcct.capabilities.get<&{CapabilityFilter.Filter}>(CapabilityFilter.PublicPath)
        if filterCap == nil || filterCap?.check() == false {
            managerAcct.capabilities.unpublish(CapabilityFilter.PublicPath)
            filterCap = managerAcct.capabilities.storage
                .issue<&AnyResource{CapabilityFilter.Filter}>(CapabilityFilter.StoragePath)
            managerAcct.capabilities.publish(filterCap!, at: CapabilityFilter.PublicPath)
        }
        return filterCap ?? panic("CapabilityFilter not found")
    }
}
