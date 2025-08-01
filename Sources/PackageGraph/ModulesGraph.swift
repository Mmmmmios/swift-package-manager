//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import OrderedCollections
import PackageLoading
import PackageModel
import TSCBasic

import protocol Basics.FileSystem
import class Basics.ObservabilityScope
import struct Basics.IdentifiableSet

enum PackageGraphError: Swift.Error {
    /// Indicates a non-root package with no modules.
    case noModules(Package)

    /// The package dependency declaration has cycle in it.
    case dependencyCycleDetected(path: [Manifest], cycle: Manifest)

    /// The product dependency not found.
    case productDependencyNotFound(
        package: String,
        moduleName: String,
        dependencyProductName: String,
        dependencyPackageName: String?,
        dependencyProductInDecl: Bool,
        similarProductName: String?,
        packageContainingSimilarProduct: String?
    )

    /// The package dependency already satisfied by a different dependency package
    ///  - package: Package for which the dependency conflict was detected.
    ///  - identity: Conflicting identity.
    ///  - dependencyLocation: Dependency from the current package which triggered the conflict.
    ///  - otherDependencyLocation: Conflicting dependency from another package.
    ///  - dependencyPath: a dependency path as a list of locations from the root to the dependency that triggered the conflict.
    ///  - otherDependencyPath: a dependency path as a list of locations from the root to the conflicting dependency from another package.
    case dependencyAlreadySatisfiedByIdentifier(
        package: String,
        identity: PackageIdentity,
        dependencyLocation: String,
        otherDependencyLocation: String,
        dependencyPath: [String] = [],
        otherDependencyPath: [String] = []
    )

    /// The package dependency already satisfied by a different dependency package
    case dependencyAlreadySatisfiedByName(
        package: String,
        dependencyLocation: String,
        otherDependencyURL: String,
        name: String
    )

    /// The product dependency was found but the package name was not referenced correctly (tools version > 5.2).
    case productDependencyMissingPackage(
        productName: String,
        moduleName: String,
        packageIdentifier: String
    )
    /// Dependency between a plugin and a dependent target/product of a given type is unsupported
    case unsupportedPluginDependency(
        moduleName: String,
        dependencyName: String,
        dependencyType: String,
        dependencyPackage: String?
    )

    /// A product was found in multiple packages.
    case duplicateProduct(product: String, packages: [Package])

    /// Duplicate aliases for a target found in a product.
    case multipleModuleAliases(
        module: String,
        product: String,
        package: String,
        aliases: [String]
    )
}

@available(*,
    deprecated,
    renamed: "ModulesGraph",
    message: "PackageGraph had a misleading name, it's a graph of dependencies between modules, not just packages"
)
public typealias PackageGraph = ModulesGraph

/// A collection of packages.
public struct ModulesGraph {
    /// The root packages.
    public let rootPackages: IdentifiableSet<ResolvedPackage>

    /// The complete set of contained packages.
    public let packages: IdentifiableSet<ResolvedPackage>

    @available(*, deprecated, renamed: "reachableModules")
    public var reachableTargets: IdentifiableSet<ResolvedModule> { self.reachableModules }

    /// The list of all modules reachable from root modules.
    public private(set) var reachableModules: IdentifiableSet<ResolvedModule>

    /// The list of all products reachable from root modules.
    public private(set) var reachableProducts: IdentifiableSet<ResolvedProduct>

    @available(*, deprecated, renamed: "allModules")
    public var allTargets: IdentifiableSet<ResolvedModule> { self.allModules }

    /// Returns all the modules in the graph, regardless if they are reachable from the root modules or not.
    public private(set) var allModules: IdentifiableSet<ResolvedModule>

    /// Returns all the products in the graph, regardless if they are reachable from the root modules or not.
    public private(set) var allProducts: IdentifiableSet<ResolvedProduct>

    /// Package dependencies required for a fully resolved graph.
    ///
    /// This will include a references to dependencies that are currently present
    /// in the graph due to loading errors. This does not include the root packages.
    public let requiredDependencies: [PackageReference]

    /// Returns true if a given module is present in root packages and is not excluded for the given build environment.
    public func isInRootPackages(_ module: ResolvedModule, satisfying buildEnvironment: BuildEnvironment) -> Bool {
        // FIXME: This can be easily cached.
        return rootPackages.reduce(
            into: IdentifiableSet<ResolvedModule>()
        ) { (accumulator: inout IdentifiableSet<ResolvedModule>, package: ResolvedPackage) in
            let allDependencies = package.modules.flatMap { $0.dependencies }
            let unsatisfiedDependencies = allDependencies.filter { !$0.satisfies(buildEnvironment) }
            let unsatisfiedDependencyModules = unsatisfiedDependencies.compactMap { (
                dep: ResolvedModule.Dependency
            ) -> ResolvedModule? in
                switch dep {
                case .module(let moduleDependency, _):
                    return moduleDependency
                default:
                    return nil
                }
            }

            accumulator.formUnion(IdentifiableSet(package.modules).subtracting(unsatisfiedDependencyModules))
        }.contains(id: module.id)
    }

    public func isRootPackage(_ package: ResolvedPackage) -> Bool {
        // FIXME: This can be easily cached.
        return self.rootPackages.contains(id: package.id)
    }

    /// Returns the package  based on the given identity, or nil if the package isn't in the graph.
    public func package(for identity: PackageIdentity) -> ResolvedPackage? {
        packages[identity]
    }

    /// Returns the package that contains the module, or nil if the module isn't in the graph.
    public func package(for module: ResolvedModule) -> ResolvedPackage? {
        self.package(for: module.packageIdentity)
    }

    /// Returns the package that contains the product, or nil if the product isn't in the graph.
    public func package(for product: ResolvedProduct) -> ResolvedPackage? {
        self.package(for: product.packageIdentity)
    }

    /// Returns all of the packages that the given package depends on directly.
    public func directDependencies(for package: ResolvedPackage) -> [ResolvedPackage] {
        package.dependencies.compactMap { self.package(for: $0) }
    }

    /// Find a product given a name and an optional destination. If a destination is not specified
    /// this method uses `.destination` and falls back to `.tools` for macros, plugins, and tests.
    public func product(for name: String) -> ResolvedProduct? {
        self.allProducts.first { $0.name == name }
    }

    @available(*, deprecated, renamed: "module(for:)")
    public func target(for name: String) -> ResolvedModule? {
        self.module(for: name)
    }

    /// Find a module given a name and an optional destination. If a destination is not specified
    /// this method uses `.destination` and falls back to `.tools` for macros, plugins, and tests.
    public func module(for name: String) -> ResolvedModule? {
        self.allModules.first { $0.name == name }
    }

    /// All root and root dependency packages provided as input to the graph.
    public let inputPackages: [ResolvedPackage]

    /// Any binary artifacts referenced by the graph.
    public let binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]]

    /// Construct a package graph directly.
    public init(
        rootPackages: [ResolvedPackage],
        rootDependencies: [ResolvedPackage] = [],
        packages: IdentifiableSet<ResolvedPackage>,
        dependencies requiredDependencies: [PackageReference],
        binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]]
    ) throws {
        let rootPackages = IdentifiableSet(rootPackages)
        self.requiredDependencies = requiredDependencies
        self.inputPackages = rootPackages + rootDependencies
        self.binaryArtifacts = binaryArtifacts
        self.packages = packages

        var allModules = IdentifiableSet<ResolvedModule>()
        var allProducts = IdentifiableSet<ResolvedProduct>()
        for package in self.packages {
            let modulesToInclude = if rootPackages.contains(id: package.id) {
                Array(package.modules)
            } else {
                // Don't include tests modules from non-root packages so swift-test doesn't
                // try to run them.
                package.modules.filter { $0.type != .test }
            }

            for module in modulesToInclude {
                allModules.insert(module)
            }

            if rootPackages.contains(id: package.id) {
                allProducts.formUnion(package.products)
            } else {
                // Don't include test products from non-root packages so swift-test doesn't
                // try to run them.
                allProducts.formUnion(package.products.filter { $0.type != .test })
            }
        }

        // Compute the reachable modules and products.
        let inputModules = self.inputPackages.flatMap { $0.modules }
        let inputProducts = self.inputPackages.flatMap { $0.products }
        let recursiveDependencies = try inputModules.lazy.flatMap { try $0.recursiveDependencies() }

        self.reachableModules = IdentifiableSet(inputModules).union(recursiveDependencies.compactMap { $0.module })
        self.reachableProducts = IdentifiableSet(inputProducts).union(recursiveDependencies.compactMap { $0.product })
        self.rootPackages = rootPackages
        self.allModules = allModules
        self.allProducts = allProducts
    }

    @_spi(SwiftPMInternal)
    @available(*, deprecated, renamed: "computeTestModulesForExecutableModules")
    public func computeTestTargetsForExecutableTargets() throws -> [ResolvedModule.ID: [ResolvedModule]] {
        try self.computeTestModulesForExecutableModules()
    }

    /// Computes a map from each executable module in any of the root packages to the corresponding test modules.
    @_spi(SwiftPMInternal)
    public func computeTestModulesForExecutableModules() throws -> [ResolvedModule.ID: [ResolvedModule]] {
        var result = [ResolvedModule.ID: [ResolvedModule]]()

        let rootModules = IdentifiableSet(rootPackages.flatMap { $0.modules })

        // Create map of test module to set of its direct dependencies.
        let testModuleDepMap: [ResolvedModule.ID: IdentifiableSet<ResolvedModule>] = try {
            let testModuleDeps = rootModules.filter({ $0.type == .test }).map({
                ($0.id, IdentifiableSet($0.dependencies.compactMap { $0.module }.filter { $0.type != .plugin }))
            })
            return try Dictionary(throwingUniqueKeysWithValues: testModuleDeps)
        }()

        for module in rootModules where module.type == .executable {
            // Find all dependencies of this module within its package. Note that we do not traverse plugin usages.
            let dependencies = try topologicalSortIdentifiable(module.dependencies, successors: {
                $0.dependencies.compactMap{ $0.module }.filter{ $0.type != .plugin }.map{ .module($0, conditions: []) }
            }).compactMap({ $0.module })

            // Include the test modules whose dependencies intersect with the
            // current module's (recursive) dependencies.
            let testModules = testModuleDepMap.filter({ (testModule, deps) in
                !deps.intersection(dependencies + [module]).isEmpty
            }).map({ $0.key })

            result[module.id] = testModules.compactMap { rootModules[$0] }
        }

        return result
    }

    public func getReplProductName() throws -> String {
        if self.rootPackages.isEmpty {
            throw StringError("Root package does not exist.")
        }
        return self.rootPackages[self.rootPackages.startIndex].identity.description +
            Product.replProductSuffix
    }
}

extension PackageGraphError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noModules(let package):
            return "package '\(package)' contains no products"

        case .dependencyCycleDetected(let path, let package):
            return "cyclic dependency between packages " +
            (path.map({ $0.displayName }).joined(separator: " -> ")) +
            " -> \(package.displayName) requires tools-version 6.0 or later"

        case .productDependencyNotFound(let package, let moduleName, let dependencyProductName, let dependencyPackageName, let dependencyProductInDecl, let similarProductName, let packageContainingSimilarProduct):
            if dependencyProductInDecl {
                return "product '\(dependencyProductName)' is declared in the same package '\(package)' and can't be used as a dependency for target '\(moduleName)'."
            } else {
                var description = "product '\(dependencyProductName)' required by package '\(package)' target '\(moduleName)' \(dependencyPackageName.map{ "not found in package '\($0)'" } ?? "not found")."
                if let similarProductName, let packageContainingSimilarProduct {
                    description += " Did you mean '.product(name: \"\(similarProductName)\", package: \"\(packageContainingSimilarProduct)\")'?"
                } else if let similarProductName {
                    description += " Did you mean '\(similarProductName)'?"
                }
                return description
            }
        case .dependencyAlreadySatisfiedByIdentifier(
            _,
            let identity,
            let dependencyURL,
            let otherDependencyURL,
            let dependencyPath,
            let otherDependencyPath
        ):
            var description =
                "Conflicting identity for \(identity): " +
                "dependency '\(dependencyURL)' and dependency '\(otherDependencyURL)' " +
                "both point to the same package identity '\(identity)'."
            if !dependencyPath.isEmpty && !otherDependencyPath.isEmpty {
                let chainA = dependencyPath.map { String(describing: $0) }.joined(separator: "->")
                let chainB = otherDependencyPath.map { String(describing: $0) }.joined(separator: "->")
                description += (
                    " The dependencies are introduced through the following chains: " +
                    "(A) \(chainA) (B) \(chainB). If there are multiple chains that lead to the same dependency, " +
                    "only the first chain is shown here. To see all chains use debug output option. " +
                    "To resolve the conflict, coordinate with the maintainer of the package " +
                    "that introduces the conflicting dependency."
                )
            }
            return description

        case .dependencyAlreadySatisfiedByName(let package, let dependencyURL, let otherDependencyURL, let name):
            return "'\(package)' dependency on '\(dependencyURL)' conflicts with dependency on '\(otherDependencyURL)' which has the same explicit name '\(name)'"

        case .productDependencyMissingPackage(
            let productName,
            let moduleName,
            let packageIdentifier
        ):

            let solution = """
            reference the package in the target dependency with '.product(name: "\(productName)", package: \
            "\(packageIdentifier)")'
            """

            return "dependency '\(productName)' in target '\(moduleName)' requires explicit declaration; \(solution)"

        case .duplicateProduct(let product, let packages):
            let packagesDescriptions = packages.sorted(by: { $0.identity < $1.identity }).map {
                var description = "'\($0.identity)'"
                switch $0.manifest.packageKind {
                case .root(let path),
                        .fileSystem(let path),
                        .localSourceControl(let path):
                    description += " (at '\(path)')"
                case .remoteSourceControl(let url):
                    description += " (from '\(url)')"
                case .registry:
                    break
                }
                return description
            }
            return "multiple packages (\(packagesDescriptions.joined(separator: ", "))) declare products with a conflicting name: '\(product)’; product names need to be unique across the package graph"
        case .multipleModuleAliases(let target, let product, let package, let aliases):
            return "multiple aliases: ['\(aliases.joined(separator: "', '"))'] found for target '\(target)' in product '\(product)' from package '\(package)'"
        case .unsupportedPluginDependency(let targetName, let dependencyName, let dependencyType,  let dependencyPackage):
            var trailingMsg = ""
            if let dependencyPackage {
              trailingMsg = " from package '\(dependencyPackage)'"
            }
            return "plugin '\(targetName)' cannot depend on '\(dependencyName)' of type '\(dependencyType)'\(trailingMsg); this dependency is unsupported"
        }
    }
}

enum GraphError: Error {
    /// A cycle was detected in the input.
    case unexpectedCycle
}

/// Perform a topological sort of an graph.
///
/// This function is optimized for use cases where cycles are unexpected, and
/// does not attempt to retain information on the exact nodes in the cycle.
///
/// - Parameters:
///   - nodes: The list of input nodes to sort.
///   - successors: A closure for fetching the successors of a particular node.
///
/// - Returns: A list of the transitive closure of nodes reachable from the
/// inputs, ordered such that every node in the list follows all of its
/// predecessors.
///
/// - Throws: GraphError.unexpectedCycle
///
/// - Complexity: O(v + e) where (v, e) are the number of vertices and edges
/// reachable from the input nodes via the relation.
func topologicalSortIdentifiable<T: Identifiable>(
    _ nodes: [T], successors: (T) throws -> [T]
) throws -> [T] {
    // Implements a topological sort via recursion and reverse postorder DFS.
    func visit(_ node: T,
               _ stack: inout OrderedCollections.OrderedSet<T.ID>, _ visited: inout Set<T.ID>, _ result: inout [T],
               _ successors: (T) throws -> [T]) throws {
        // Mark this node as visited -- we are done if it already was.
        if !visited.insert(node.id).inserted {
            return
        }

        // Otherwise, visit each adjacent node.
        for succ in try successors(node) {
            guard stack.append(succ.id).inserted else {
                // If the successor is already in this current stack, we have found a cycle.
                //
                // FIXME: We could easily include information on the cycle we found here.
                throw GraphError.unexpectedCycle
            }
            try visit(succ, &stack, &visited, &result, successors)
            let popped = stack.removeLast()
            assert(popped == succ.id)
        }

        // Add to the result.
        result.append(node)
    }

    // FIXME: This should use a stack not recursion.
    var visited = Set<T.ID>()
    var result = [T]()
    var stack = OrderedCollections.OrderedSet<T.ID>()
    for node in nodes {
        precondition(stack.isEmpty)
        stack.append(node.id)
        try visit(node, &stack, &visited, &result, successors)
        let popped = stack.removeLast()
        assert(popped == node.id)
    }

    return result.reversed()
}

@_spi(DontAdoptOutsideOfSwiftPMExposedForBenchmarksAndTestsOnly)
public func loadModulesGraph(
    identityResolver: IdentityResolver = DefaultIdentityResolver(),
    fileSystem: FileSystem,
    manifests: [Manifest],
    binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]] = [:],
    prebuilts: [PackageIdentity: [String: PrebuiltLibrary]] = [:],
    explicitProduct: String? = .none,
    shouldCreateMultipleTestProducts: Bool = false,
    createREPLProduct: Bool = false,
    useXCBuildFileRules: Bool = false,
    customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
    observabilityScope: ObservabilityScope,
    traitConfiguration: TraitConfiguration = .default
) throws -> ModulesGraph {
    let rootManifests = manifests.filter(\.packageKind.isRoot).spm_createDictionary { ($0.path, $0) }
    let externalManifests = try manifests.filter { !$0.packageKind.isRoot }
        .reduce(
            into: OrderedCollections
                .OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>()
        ) { partial, item in
            partial[try identityResolver.resolveIdentity(for: item.packageKind)] = (item, fileSystem)
        }

    let packages = Array(rootManifests.keys)

    let manifestMap = manifests.reduce(into: [PackageIdentity: Manifest]()) { manifestMap, manifest in
        manifestMap[manifest.packageIdentity] = manifest
    }

    // Note: The following is a copy of the existing `Workspace.precomputeTraits` method
    func precomputeTraits(
        _ enabledTraitsMap: EnabledTraitsMap,
        _ topLevelManifests: [Manifest],
        _ manifestMap: [PackageIdentity: Manifest]
    ) throws -> [PackageIdentity: Set<String>] {
        var visited: Set<PackageIdentity> = []
        var enabledTraitsMap = enabledTraitsMap

        func dependencies(of parent: Manifest, _ productFilter: ProductFilter = .everything) throws {
            let parentTraits = enabledTraitsMap[parent.packageIdentity]
            let requiredDependencies = try parent.dependenciesRequired(for: productFilter, parentTraits)
            let guardedDependencies = parent.dependenciesTraitGuarded(withEnabledTraits: parentTraits)

            _ = try (requiredDependencies + guardedDependencies).compactMap({ dependency in
                return try manifestMap[dependency.identity].flatMap({ manifest in

                    let explicitlyEnabledTraits = dependency.traits?.filter {
                        guard let condition = $0.condition else { return true }
                        return condition.isSatisfied(by: parentTraits)
                    }.map(\.name)

                    var enabledTraitsSet = explicitlyEnabledTraits.flatMap { Set($0) }
                    let precomputedTraits = enabledTraitsMap[dependency.identity]

                    if precomputedTraits == ["default"],
                       let enabledTraitsSet {
                        enabledTraitsMap[dependency.identity] = enabledTraitsSet
                    } else {
                        // unify traits
                        enabledTraitsSet?.formUnion(precomputedTraits)
                        if let enabledTraitsSet {
                            enabledTraitsMap[dependency.identity] = enabledTraitsSet
                        }
                    }

                    let calculatedTraits = try manifest.enabledTraits(
                        using: enabledTraitsSet ?? ["default"],
                        .init(parent)
                    )

                    enabledTraitsMap[dependency.identity] = calculatedTraits
                    let result = visited.insert(dependency.identity)
                    if result.inserted {
                        try dependencies(of: manifest, dependency.productFilter)
                    }

                    return manifest
                })
            })
        }

        for manifest in topLevelManifests {
            // Track already-visited manifests to avoid cycles
            let result = visited.insert(manifest.packageIdentity)
            if result.inserted {
                try dependencies(of: manifest)
            }
        }

        return enabledTraitsMap.dictionaryLiteral
    }


    // Precompute enabled traits for roots.
    var enabledTraitsMap: EnabledTraitsMap = [:]
    for root in rootManifests.values {
        let enabledTraits = try root.enabledTraits(using: traitConfiguration)
        enabledTraitsMap[root.packageIdentity] = enabledTraits
    }
    enabledTraitsMap = .init(try precomputeTraits(enabledTraitsMap, manifests, manifestMap))

    let input = PackageGraphRootInput(packages: packages, traitConfiguration: traitConfiguration)
    let graphRoot = try PackageGraphRoot(
        input: input,
        manifests: rootManifests,
        explicitProduct: explicitProduct,
        observabilityScope: observabilityScope,
        enabledTraitsMap: enabledTraitsMap
    )

    return try ModulesGraph.load(
        root: graphRoot,
        identityResolver: identityResolver,
        additionalFileRules: useXCBuildFileRules ? FileRuleDescription.xcbuildFileTypes : FileRuleDescription
            .swiftpmFileTypes,
        externalManifests: externalManifests,
        binaryArtifacts: binaryArtifacts,
        prebuilts: prebuilts,
        shouldCreateMultipleTestProducts: shouldCreateMultipleTestProducts,
        createREPLProduct: createREPLProduct,
        customXCTestMinimumDeploymentTargets: customXCTestMinimumDeploymentTargets,
        fileSystem: fileSystem,
        observabilityScope: observabilityScope,
        productsFilter: nil,
        modulesFilter: nil,
        enabledTraitsMap: enabledTraitsMap
    )
}
