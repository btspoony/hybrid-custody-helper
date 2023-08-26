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

    /* --- Canonical Paths --- */
    pub let WrapperStoragePath: StoragePath;

    /// Wrapper resource
    /// No public interface, only the owner can access the resource
    ///
    pub resource Wrapper {
        /// The AuthAccount capability of the manager account
        /// we have to use the AuthAccount capability to access the manager account
        access(self) let managerAcct: Capability<&AuthAccount>

        init(
            _ managerAcct: Capability<&AuthAccount>
        ) {
            pre {
                managerAcct.check(): "Manager account capability is invalid"
            }
            self.managerAcct = managerAcct
        }

        // ------- Mamager Methods ------

        /// Return the manager address
        ///
        pub fun getManagerAddress(): Address {
            return self.managerAcct.address
        }

        /// Borrow the manager account
        ///
        pub fun borrowManagerAuthAccount(): &AuthAccount {
            return self.managerAcct.borrow()
                ?? panic("Failed to fetch manager account")
        }

        /// Borrow the hybrid custody ChildAccount manager
        ///
        pub fun borrowHybridCustoryAccountManager(): &HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}? {
            let managerAcct = self.borrowManagerAuthAccount()
            return managerAcct.borrow<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}>(from: HybridCustody.ManagerStoragePath)
        }

        // ------- Child Methods ------

        /// Setup the child account for the manager
        ///
        /// - managerAcct: the account of the manager
        /// - childAcctCap: the capability of the child account
        ///
        pub fun setupNewChild(
            _ childAcctCap: Capability<&AuthAccount>,
        ) {
            pre {
                childAcctCap.check(): "Child account capability is invalid"
            }
            // >>> [0] Ensure the manager resource exists

            self.ensureManagerExists()

            let managerAcct = self.borrowManagerAuthAccount()
            let managerAddress = self.getManagerAddress()
            let manager = self.borrowHybridCustoryAccountManager()
                ?? panic("Failed to borrow hybrid custody manager.")
            let child = childAcctCap.borrow()
                ?? panic("Failed to borrow child account")

            // >>> [1] Child: createOwnedAccount

            if child.borrow<&HybridCustody.OwnedAccount>(from: HybridCustody.OwnedAccountStoragePath) == nil {
                let ownedAccount <- HybridCustody.createOwnedAccount(acct: childAcctCap)
                child.save(<-ownedAccount, to: HybridCustody.OwnedAccountStoragePath)
            }

            // publish to new public path
            child.capabilities.unpublish(HybridCustody.OwnedAccountPublicPath)
            let ownedChildCap = child.capabilities.storage
                .issue<&HybridCustody.OwnedAccount{HybridCustody.BorrowableAccount, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}>(HybridCustody.OwnedAccountStoragePath)
            child.capabilities.publish(ownedChildCap, at: HybridCustody.OwnedAccountPublicPath)

            // Compatible with older versions
            // @deprecated
            child.link<&HybridCustody.OwnedAccount{HybridCustody.BorrowableAccount, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}>(
                HybridCustody.OwnedAccountPrivatePath,
                target: HybridCustody.OwnedAccountStoragePath
            )

            // >>> [2] Child: giveOwnership
            let owned = child.borrow<&HybridCustody.OwnedAccount>(from: HybridCustody.OwnedAccountStoragePath)
                ?? panic("owned not found in child account")
            owned.giveOwnership(to: managerAddress)

            // >>> [3] Manager: Accept OwnedAccount capablity and AddOwnedAccount

            // generate inboxName by manager address
            let ownedAccountInboxName = HybridCustody.getOwnerIdentifier(managerAddress)
            let ownedAccountCap = managerAcct.inbox
                .claim<&AnyResource{HybridCustody.OwnedAccountPrivate, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}>(ownedAccountInboxName, provider: child.address)
                ?? panic("owned account cap not found")

            manager.addOwnedAccount(cap: ownedAccountCap)

            // >>> [4] Child: publishToParent

            // get the owned acount reference again, but this time get from manager
            let ownedChildFromManager = manager.borrowOwnedAccount(addr: child.address)
                ?? panic("owned account not found from manager")

            ownedChildFromManager.publishToParent(
                parentAddress: managerAddress,
                // The factory manager is used to fetch capabilities through capability factory
                factory: self.fetchOrCreateCapabilityFactory(),
                // you can change the filter later, currently use allow all
                filter: self.fetchOrCreateAllowAllCapabilityFilter(),
            )

            // >>> [5] Manager: Accept ChildAccount capablity and AddAccount

            let childAccountInboxName = HybridCustody.getChildAccountIdentifier(managerAddress)
            let childAccountCap = managerAcct.inbox
                .claim<&HybridCustody.ChildAccount{HybridCustody.AccountPrivate, HybridCustody.AccountPublic, MetadataViews.Resolver}>(childAccountInboxName, provider: child.address)
                ?? panic("child account cap not found")

            manager.addAccount(cap: childAccountCap)

            // >>> [6] post checker as the post-condition, for view function is required by post-condition
            assert(
                // ensure child account can be borrowed from manager
                self.borrowHybridCustoryAccountManager()
                    ?.borrowAccountPublic(addr: childAcctCap.address) != nil,
                message: "Failed to add child account"
            )
        }

        // ------------ Borrow Children ------------

        /// Borrow the AuthAccount of child account from the manager, if the child account is not found, return nil
        ///
        pub fun borrowChildAuthAccount(
            _ childAddress: Address,
        ): &AuthAccount? {
            post {
                result == nil || result?.address == childAddress: "Failed to borrow child account"
            }

            if let owned = self.borrowChildOwnedAccount(childAddress) {
                return owned.borrowAccount()
            }
            return nil
        }

        /// Borrow the OwnedAccount of child account from the manager, if the child account is not found, return nil
        ///
        pub fun borrowChildOwnedAccount(
            _ childAddress: Address,
        ): &AnyResource{HybridCustody.OwnedAccountPrivate, HybridCustody.OwnedAccountPublic, MetadataViews.Resolver}? {
            // >>> [0] Ensure the manager resource exists
            self.ensureManagerExists()

            // >>> [1] borrow owned account from manager
            if let manager = self.borrowHybridCustoryAccountManager() {
                return manager.borrowOwnedAccount(addr: childAddress)
            }
            return nil
        }

        /// Borrow the ChildAccount of child account from the manager, if the child account is not found, return nil
        ///
        pub fun borrowChildAccount(
            _ childAddress: Address,
        ): &AnyResource{HybridCustody.AccountPrivate, HybridCustody.AccountPublic, MetadataViews.Resolver}? {
            // >>> [0] Ensure the manager resource exists
            self.ensureManagerExists()

            // >>> [1] borrow owned account from manager
            if let manager = self.borrowHybridCustoryAccountManager() {
                return manager.borrowAccount(addr: childAddress)
            }
            return nil
        }

        /// Borrow the ChildAccountPublic of child account from the manager, if the child account is not found, return nil
        ///
        pub fun borrowChildAccountPublic(
            _ childAddress: Address,
        ): &AnyResource{HybridCustody.AccountPublic, MetadataViews.Resolver}? {
            return HybridCustodyHelper.borrowChildAccountPublic(self.getManagerAddress(), childAddress)
        }

        // ------------ Capability setter ------------

        /// Add the capability to the owned child account
        ///
        pub fun addCapabilityToOwnedChild(
            _ childAddress: Address,
            capability: Capability,
            isPublic: Bool
        ) {
            // >>> [0] Ensure the manager resource exists
            self.ensureManagerExists()

            // >>> [1] borrow owned account from manager
            let manager = self.borrowHybridCustoryAccountManager()
                ?? panic("Failed to borrow manager")

            let owned = manager.borrowOwnedAccount(addr: childAddress)
                ?? panic("The child address is not an owned account.")

            owned.addCapabilityToDelegator(parent: self.getManagerAddress(), cap: capability, isPublic: isPublic)
        }

        /// Remove the capability from the owned child account
        ///
        pub fun removeCapabilityFromOwnedChild(
            _ childAddress: Address,
            capability: Capability,
        ) {
            // >>> [0] Ensure the manager resource exists
            self.ensureManagerExists()

            // >>> [1] borrow owned account from manager
            let manager = self.borrowHybridCustoryAccountManager()
                ?? panic("Failed to borrow manager")

            let owned = manager.borrowOwnedAccount(addr: childAddress)
                ?? panic("The child address is not an owned account.")

            owned.removeCapabilityFromDelegator(parent: self.getManagerAddress(), cap: capability)
        }

        // ------------ Fetching capability ------------

        /// Fetch the private/public capability from the manager by Capability Factory
        ///
        pub fun getCapabilityFromFactory(
            _ childAddress: Address,
            path: CapabilityPath,
            type: Type
        ): Capability? {
            if let childPrivRef = self.borrowChildAccount(childAddress) {
                return childPrivRef.getCapability(path: path, type: type)
            }
            return nil
        }

        /// Fetch the private/public capability from the manager by Capability Delegator
        ///
        pub fun getCapabilityFromDelegator(
            _ childAddress: Address,
            type: Type,
        ): Capability? {
            if let childPrivRef = self.borrowChildAccount(childAddress) {
                return childPrivRef.getPrivateCapFromDelegator(type: type) ?? childPrivRef.getPublicCapFromDelegator(type: type)
            }
            return nil
        }

        /// Fetch the public capability from the manager by Capability Factory
        ///
        pub fun getPublicCapabilityFromFactory(
            _ childAddress: Address,
            path: PublicPath,
            type: Type
        ): Capability? {
            return HybridCustodyHelper.getPublicCapabilityFromFactory(self.getManagerAddress(), childAddress, path: path, type: type)
        }

        /// Fetch the public capability from the manager by Capability Delegator
        ///
        pub fun getPublicCapabilityFromDelegator(
            _ childAddress: Address,
            type: Type
        ): Capability? {
            return HybridCustodyHelper.getPublicCapabilityFromDelegator(self.getManagerAddress(), childAddress, type: type)
        }

        /// Ensure the manager resource exists in the account
        ///
        pub fun ensureManagerExists() {
            post {
                self.managerAcct.borrow()?.borrow<&HybridCustody.Manager>(from: HybridCustody.ManagerStoragePath) != nil: "Failed to create manager"
                self.managerAcct.borrow()?.capabilities?.get<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(HybridCustody.ManagerPublicPath) != nil: "Failed to publish mananger pub cap"
            }
            let managerAcct = self.managerAcct.borrow() ?? panic("Failed to borrow manager account")

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
        pub fun issueManagerPrivateCapability(): Capability<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}> {
            post {
                result.check(): "Failed to issue a new private capability"
            }
            let managerAcct = self.borrowManagerAuthAccount()
            // issue a new private capability
            return managerAcct.capabilities.storage
                .issue<&HybridCustody.Manager{HybridCustody.ManagerPublic, HybridCustody.ManagerPrivate}>(HybridCustody.ManagerStoragePath)
        }

        /// Fetch or create a capability factory capability
        ///
        pub fun fetchOrCreateCapabilityFactory(): Capability<&CapabilityFactory.Manager{CapabilityFactory.Getter}> {
            post {
                result.check(): "CapabilityFactory is not setup properly"
            }
            let managerAcct = self.borrowManagerAuthAccount()

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
        pub fun fetchOrCreateAllowAllCapabilityFilter(): Capability<&{CapabilityFilter.Filter}> {
            post {
                result.check() == true: "CapabilityFilter is not setup properly"
                result.borrow()!.getType() == Type<@CapabilityFilter.AllowAllFilter>(): "CapabilityFilter in account is not AllowAll Filter"
            }
            return self._fetchOrCreateCapabilityFilter(Type<@CapabilityFilter.AllowAllFilter>())
        }

        /// Fetch or create the allow list filter capability
        ///
        pub fun fetchOrCreateAllowlistCapabilityFilter(): Capability<&{CapabilityFilter.Filter}> {
            post {
                result.check() == true: "CapabilityFilter is not setup properly"
                result.borrow()!.getType() == Type<@CapabilityFilter.AllowlistFilter>(): "CapabilityFilter in account is not Allowlist Filter"
            }
            return self._fetchOrCreateCapabilityFilter(Type<@CapabilityFilter.AllowlistFilter>())
        }

        /// Fetch or create the deny list filter capability
        ///
        pub fun fetchOrCreateDenylistCapabilityFilter(): Capability<&{CapabilityFilter.Filter}> {
            post {
                result.check() == true: "CapabilityFilter is not setup properly"
                result.borrow()!.getType() == Type<&CapabilityFilter.DenylistFilter>(): "CapabilityFilter in account is not Denylist Filter"
            }
            return self._fetchOrCreateCapabilityFilter(Type<@CapabilityFilter.DenylistFilter>())
        }

        // -------- Internal Methods --------

        /// Fetch or create a capability filter capability
        ///
        access(self) fun _fetchOrCreateCapabilityFilter(_ t: Type): Capability<&{CapabilityFilter.Filter}> {
            post {
                result.check(): "CapabilityFilter is not setup properly"
            }
            let managerAcct = self.borrowManagerAuthAccount()

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

    /// Public wrapper struct for the HybridCustody Manager
    ///
    pub struct PublicWrapper {
        pub let manager: Address
        pub let child: Address

        init(_ manager: Address, _ child: Address) {
            self.manager = manager
            self.child = child
        }

        /// Borrow the ChildAccountPublic of child account from the manager, if the child account is not found, return nil
        ///
        pub fun borrowChildAccountPublic(): &AnyResource{HybridCustody.AccountPublic, MetadataViews.Resolver}? {
            return HybridCustodyHelper.borrowChildAccountPublic(self.manager, self.child)
        }

        /// Fetch the public capability from the manager by Capability Factory
        ///
        pub fun getPublicCapabilityFromFactory(path: PublicPath, type: Type): Capability? {
            return HybridCustodyHelper.getPublicCapabilityFromFactory(self.manager, self.child, path: path, type: type)
        }

        /// Fetch the public capability from the manager by Capability Delegator
        ///
        pub fun getPublicCapabilityFromDelegator(type: Type): Capability? {
            return HybridCustodyHelper.getPublicCapabilityFromDelegator(self.manager, self.child, type: type)
        }
    }

    // ------ Public Methods ------

    /// Create a new HybridCustody Wrapper
    ///
    pub fun createWrapper(
        _ managerAcctCap: Capability<&AuthAccount>
    ): @Wrapper {
        return <- create Wrapper(managerAcctCap)
    }

    // ----- Internal Methods -----

    /// Borrow the ChildAccountPublic of child account from the manager, if the child account is not found, return nil
    ///
    access(contract) fun borrowChildAccountPublic(
        _ managerAddress: Address,
        _ childAddress: Address,
    ): &AnyResource{HybridCustody.AccountPublic, MetadataViews.Resolver}? {
        // >>> [0] Borrow the manager public capability
        let managerPubCap = getAccount(managerAddress).capabilities
            .get<&HybridCustody.Manager{HybridCustody.ManagerPublic}>(HybridCustody.ManagerPublicPath)
        if managerPubCap == nil || managerPubCap?.check() == false {
            return nil
        }
        return managerPubCap!.borrow()!.borrowAccountPublic(addr: childAddress)
    }

    /// Fetch the public capability from the manager by Capability Factory
    ///
    access(contract) fun getPublicCapabilityFromFactory(
        _ managerAddress: Address,
        _ childAddress: Address,
        path: PublicPath,
        type: Type
    ): Capability? {
        if let childPubRef = self.borrowChildAccountPublic(managerAddress, childAddress) {
            return childPubRef.getPublicCapability(path: path, type: type)
        }
        return nil
    }

    /// Fetch the public capability from the manager by Capability Delegator
    ///
    access(contract) fun getPublicCapabilityFromDelegator(
        _ managerAddress: Address,
        _ childAddress: Address,
        type: Type,
    ): Capability? {
        if let childPubRef = self.borrowChildAccountPublic(managerAddress, childAddress) {
            return childPubRef.getPublicCapFromDelegator(type: type)
        }
        return nil
    }

    init() {
        let identifier = "HybridCustodyHelper_".concat(self.account.address.toString())
        self.WrapperStoragePath = StoragePath(identifier: identifier)!
    }
}
