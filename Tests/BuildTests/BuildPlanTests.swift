/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import TSCBasic
import TSCUtility
import SPMTestSupport
import PackageModel
import PackageLoading

import Build

#if os(macOS)
    let defaultTargetTriple: String = Triple.hostTriple.tripleString(forPlatformVersion: "10.10")
#else
    let defaultTargetTriple: String = Triple.hostTriple.tripleString
#endif

private struct MockToolchain: Toolchain {
    let swiftCompiler = AbsolutePath("/fake/path/to/swiftc")
    let extraCCFlags: [String] = []
    let extraSwiftCFlags: [String] = []
    #if os(macOS)
    let extraCPPFlags: [String] = ["-lc++"]
    #else
    let extraCPPFlags: [String] = ["-lstdc++"]
    #endif
    func getClangCompiler() throws -> AbsolutePath {
        return AbsolutePath("/fake/path/to/clang")
    }

    func _isClangCompilerVendorApple() throws -> Bool? {
      #if os(macOS)
        return true
      #else
        return false
      #endif
    }
}

final class BuildPlanTests: XCTestCase {

    /// The j argument.
    private var j: String {
        return "-j3"
    }

    func mockBuildParameters(
        buildPath: AbsolutePath = AbsolutePath("/path/to/build"),
        config: BuildConfiguration = .debug,
        flags: BuildFlags = BuildFlags(),
        shouldLinkStaticSwiftStdlib: Bool = false,
        destinationTriple: Triple = Triple.hostTriple,
        indexStoreMode: BuildParameters.IndexStoreMode = .off
    ) -> BuildParameters {
        return BuildParameters(
            dataPath: buildPath,
            configuration: config,
            toolchain: MockToolchain(),
            destinationTriple: destinationTriple,
            flags: flags,
            jobs: 3,
            shouldLinkStaticSwiftStdlib: shouldLinkStaticSwiftStdlib,
            indexStoreMode: indexStoreMode
        )
    }

    func testBasicSwiftPackage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(shouldLinkStaticSwiftStdlib: true),
            graph: graph, diagnostics: diagnostics, fileSystem: fs)
        )

        result.checkProductsCount(1)
        result.checkTargetsCount(2)

        let exe = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exe, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

        let lib = try result.target(for: "lib").swiftTarget().compileArguments()
        XCTAssertMatch(lib, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

      #if os(macOS)
        let linkArguments = [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe",
            "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10", "-Xlinker", "-add_ast_path",
            "-Xlinker", "/path/to/build/debug/exe.swiftmodule", "-Xlinker", "-add_ast_path",
            "-Xlinker", "/path/to/build/debug/lib.swiftmodule",
        ]
      #else
        let linkArguments = [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe",
            "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ]
      #endif

        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), linkArguments)

      #if os(macOS)
        DiagnosticsEngineTester(diagnostics) { result in
            result.check(diagnostic: .contains("can be downloaded"), behavior: .warning)
        }
      #else
        XCTAssertNoDiagnostics(diagnostics)
      #endif
    }

    func testBasicExtPackages() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/A/Tests/ATargetTests/foo.swift",
            "/A/Tests/LinuxMain.swift",
            "/B/Sources/BTarget/foo.swift",
            "/B/Tests/BTargetTests/foo.swift",
            "/B/Tests/LinuxMain.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "A",
                    path: "/A",
                    url: "/A",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BLibrary"]),
                        TargetDescription(name: "ATargetTests", dependencies: ["ATarget"], type: .test),
                    ]),
                Manifest.createV4Manifest(
                    name: "B",
                    path: "/B",
                    url: "/B",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "BLibrary", targets: ["BTarget"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget", dependencies: []),
                        TargetDescription(name: "BTargetTests", dependencies: ["BTarget"], type: .test),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics,
            fileSystem: fileSystem))

        XCTAssertEqual(Set(result.productMap.keys), ["APackageTests"])
      #if os(macOS)
        XCTAssertEqual(Set(result.targetMap.keys), ["ATarget", "BTarget", "ATargetTests"])
      #else
        XCTAssertEqual(Set(result.targetMap.keys), [
            "APackageTests",
            "ATarget",
            "ATargetTests",
            "BTarget"
        ])
      #endif
    }

    func testBasicReleasePackage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(config: .release), graph: graph, diagnostics: diagnostics, fileSystem: fs))

        result.checkProductsCount(1)
        result.checkTargetsCount(1)

        let exe = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exe, ["-swift-version", "4", "-O", "-g", .equal(j), "-DSWIFT_PACKAGE", "-module-cache-path", "/path/to/build/release/ModuleCache", .anySequence])

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-g", "-L", "/path/to/build/release",
            "-o", "/path/to/build/release/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/release/exe.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-g", "-L", "/path/to/build/release",
            "-o", "/path/to/build/release/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/release/exe.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])
      #endif
    }

    func testBasicClangPackage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.c",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/lib.S",
            "/Pkg/Sources/lib/include/lib.h",
            "/ExtPkg/Sources/extlib/extlib.c",
            "/ExtPkg/Sources/extlib/include/ext.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/ExtPkg", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: ["ExtPkg"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "ExtPkg",
                    path: "/ExtPkg",
                    url: "/ExtPkg",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "ExtPkg", targets: ["extlib"]),
                    ],
                    targets: [
                        TargetDescription(name: "extlib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))

        result.checkProductsCount(1)
        result.checkTargetsCount(3)

        let ext = try result.target(for: "extlib").clangTarget()
        var args: [String] = []

      #if os(macOS)
        args += ["-fobjc-arc", "-target", defaultTargetTriple]
      #else
        args += ["-target", defaultTargetTriple]
      #endif

        args += ["-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1"]
        args += ["-fblocks", "-fmodules", "-fmodule-name=extlib",
            "-I", "/ExtPkg/Sources/extlib/include", "-fmodules-cache-path=/path/to/build/debug/ModuleCache"]
        XCTAssertEqual(ext.basicArguments(), args)
        XCTAssertEqual(ext.objects, [AbsolutePath("/path/to/build/debug/extlib.build/extlib.c.o")])
        XCTAssertEqual(ext.moduleMap, AbsolutePath("/path/to/build/debug/extlib.build/module.modulemap"))

        let exe = try result.target(for: "exe").clangTarget()
        args = []

      #if os(macOS)
        args += ["-fobjc-arc", "-target", defaultTargetTriple]
      #else
        args += ["-target", defaultTargetTriple]
      #endif

        args += ["-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1"]
        args += ["-fblocks", "-fmodules", "-fmodule-name=exe",
            "-I", "/Pkg/Sources/exe/include", "-I", "/Pkg/Sources/lib/include",
            "-fmodule-map-file=/path/to/build/debug/lib.build/module.modulemap",
            "-I", "/ExtPkg/Sources/extlib/include",
            "-fmodule-map-file=/path/to/build/debug/extlib.build/module.modulemap",
            "-fmodules-cache-path=/path/to/build/debug/ModuleCache",
        ]
        XCTAssertEqual(exe.basicArguments(), args)
        XCTAssertEqual(exe.objects, [AbsolutePath("/path/to/build/debug/exe.build/main.c.o")])
        XCTAssertEqual(exe.moduleMap, nil)

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-runtime-compatibility-version", "none",
            "-target", "x86_64-apple-macosx10.10",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-runtime-compatibility-version", "none",
            "-target", defaultTargetTriple,
        ])
      #endif

      let linkedFileList = try fs.readFileContents(AbsolutePath("/path/to/build/debug/exe.product/Objects.LinkFileList"))
      XCTAssertEqual(linkedFileList, """
          /path/to/build/debug/exe.build/main.c.o
          /path/to/build/debug/extlib.build/extlib.c.o
          /path/to/build/debug/lib.build/lib.c.o

          """)
    }

    func testCLanguageStandard() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.cpp",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/libx.cpp",
            "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    cLanguageStandard: "gnu99",
                    cxxLanguageStandard: "c++1z",
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)
        let result = BuildPlanResult(plan: plan)

        result.checkProductsCount(1)
        result.checkTargetsCount(2)

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-lc++", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-runtime-compatibility-version", "none",
            "-target", "x86_64-apple-macosx10.10",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-lstdc++", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-runtime-compatibility-version", "none",
            "-target", defaultTargetTriple,
        ])
      #endif

        mktmpdir { path in
            let yaml = path.appending(component: "debug.yaml")
            let llbuild = LLBuildManifestBuilder(plan)
            try llbuild.generateManifest(at: yaml)
            let contents = try localFileSystem.readFileContents(yaml).description
            XCTAssertTrue(contents.contains("-std=gnu99\",\"-c\",\"/Pkg/Sources/lib/lib.c"))
            XCTAssertTrue(contents.contains("-std=c++1z\",\"-c\",\"/Pkg/Sources/lib/libx.cpp"))
        }
    }

    func testSwiftCMixed() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
        result.checkTargetsCount(2)

        let lib = try result.target(for: "lib").clangTarget()
        var args: [String] = []

      #if os(macOS)
        args += ["-fobjc-arc", "-target", defaultTargetTriple]
      #else
        args += ["-target", defaultTargetTriple]
      #endif

        args += ["-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1"]
        args += ["-fblocks", "-fmodules", "-fmodule-name=lib", "-I", "/Pkg/Sources/lib/include",
            "-fmodules-cache-path=/path/to/build/debug/ModuleCache"]
        XCTAssertEqual(lib.basicArguments(), args)
        XCTAssertEqual(lib.objects, [AbsolutePath("/path/to/build/debug/lib.build/lib.c.o")])
        XCTAssertEqual(lib.moduleMap, AbsolutePath("/path/to/build/debug/lib.build/module.modulemap"))

        let exe = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exe, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG","-Xcc", "-fmodule-map-file=/path/to/build/debug/lib.build/module.modulemap", "-I", "/Pkg/Sources/lib/include", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/exe.swiftmodule",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])
      #endif
    }

    func testSwiftCAsmMixed() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/lib.S",
            "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(
            fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createManifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    v: .v5,
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
        result.checkTargetsCount(2)

        let lib = try result.target(for: "lib").clangTarget()
        XCTAssertEqual(lib.objects, [
            AbsolutePath("/path/to/build/debug/lib.build/lib.S.o"),
            AbsolutePath("/path/to/build/debug/lib.build/lib.c.o")
        ])
    }

    func testREPLArguments() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/swiftlib/lib.swift",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/include/lib.h",
            "/Dep/Sources/Dep/dep.swift",
            "/Dep/Sources/CDep/cdep.c",
            "/Dep/Sources/CDep/include/head.h",
            "/Dep/Sources/CDep/include/module.modulemap"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/Dep", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["swiftlib"]),
                        TargetDescription(name: "swiftlib", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: ["Dep"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "Dep",
                    path: "/Dep",
                    url: "/Dep",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "Dep", targets: ["Dep"]),
                    ],
                    targets: [
                        TargetDescription(name: "Dep", dependencies: ["CDep"]),
                        TargetDescription(name: "CDep", dependencies: []),
                    ]),
            ],
            createREPLProduct: true
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)
        XCTAssertEqual(plan.createREPLArguments().sorted(), ["-I/Dep/Sources/CDep/include", "-I/path/to/build/debug", "-I/path/to/build/debug/lib.build", "-L/path/to/build/debug", "-lPkg__REPL"])

        XCTAssertEqual(plan.graph.allProducts.map({ $0.name }).sorted(), [
            "Dep",
            "Pkg__REPL",
            "exe",
        ])
    }

    func testTestModule() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/Foo/foo.swift",
            "/Pkg/Tests/LinuxMain.swift",
            "/Pkg/Tests/FooTests/foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "Foo", dependencies: []),
                        TargetDescription(name: "FooTests", dependencies: ["Foo"], type: .test),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
      #if os(macOS)
        result.checkTargetsCount(2)
      #else
        // We have an extra LinuxMain target on linux.
        result.checkTargetsCount(3)
      #endif

        let foo = try result.target(for: "Foo").swiftTarget().compileArguments()
        XCTAssertMatch(foo, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

        let fooTests = try result.target(for: "FooTests").swiftTarget().compileArguments()
        XCTAssertMatch(fooTests, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "PkgPackageTests").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/PkgPackageTests.xctest/Contents/MacOS/PkgPackageTests", "-module-name",
            "PkgPackageTests", "-Xlinker", "-bundle",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../",
            "@/path/to/build/debug/PkgPackageTests.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/Foo.swiftmodule",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/FooTests.swiftmodule",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "PkgPackageTests").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/PkgPackageTests.xctest", "-module-name", "PkgPackageTests", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/PkgPackageTests.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])
      #endif
    }

    func testCModule() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Clibgit/module.modulemap"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "Clibgit", requirement: .upToNextMajor(from: "1.0.0"))
                    ],
                    targets: [
                        TargetDescription(name: "exe", dependencies: []),
                    ]),
                Manifest.createV4Manifest(
                    name: "Clibgit",
                    path: "/Clibgit",
                    url: "/Clibgit",
                    packageKind: .local),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
        result.checkTargetsCount(1)

        XCTAssertMatch(try result.target(for: "exe").swiftTarget().compileArguments(), ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-Xcc", "-fmodule-map-file=/Clibgit/module.modulemap", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

      #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/exe.swiftmodule",
        ])
      #else
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])
      #endif
    }

    func testCppModule() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.cpp",
            "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "lib", dependencies: []),
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
        result.checkTargetsCount(2)
        let linkArgs = try result.buildProduct(for: "exe").linkArguments()

      #if os(macOS)
        XCTAssertTrue(linkArgs.contains("-lc++"))
      #else
        XCTAssertTrue(linkArgs.contains("-lstdc++"))
      #endif
    }

    func testDynamicProducts() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Foo/main.swift",
            "/Bar/Source/Bar/source.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let g = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Bar",
                    path: "/Bar",
                    url: "/Bar",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "Bar-Baz", type: .library(.dynamic), targets: ["Bar"]),
                    ],
                    targets: [
                        TargetDescription(name: "Bar", dependencies: []),
                    ]),
                Manifest.createV4Manifest(
                    name: "Foo",
                    path: "/Foo",
                    url: "/Foo",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/Bar", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "Foo", dependencies: ["Bar-Baz"]),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(), graph: g, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(2)
        result.checkTargetsCount(2)

        let fooLinkArgs = try result.buildProduct(for: "Foo").linkArguments()
        let barLinkArgs = try result.buildProduct(for: "Bar-Baz").linkArguments()

      #if os(macOS)
        XCTAssertEqual(fooLinkArgs, [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
           "-o", "/path/to/build/debug/Foo", "-module-name", "Foo", "-lBar-Baz", "-emit-executable",
           "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/Foo.product/Objects.LinkFileList",
            "-Xlinker", "-rpath", "-Xlinker", "/fake/path/lib/swift/macosx",
            "-target", "x86_64-apple-macosx10.10",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/Foo.swiftmodule"
        ])

        XCTAssertEqual(barLinkArgs, [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/libBar-Baz.dylib",
            "-module-name", "Bar_Baz", "-emit-library",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libBar-Baz.dylib",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            "@/path/to/build/debug/Bar-Baz.product/Objects.LinkFileList",
            "-target", "x86_64-apple-macosx10.10",
            "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/Bar.swiftmodule"
        ])
      #else
        XCTAssertEqual(fooLinkArgs, [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
            "-o", "/path/to/build/debug/Foo", "-module-name", "Foo", "-lBar-Baz", "-emit-executable",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/Foo.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])

        XCTAssertEqual(barLinkArgs, [
            "/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o",
            "/path/to/build/debug/libBar-Baz.so",
            "-module-name", "Bar_Baz", "-emit-library",
            "-Xlinker", "-rpath=$ORIGIN",
            "@/path/to/build/debug/Bar-Baz.product/Objects.LinkFileList",
            "-target", defaultTargetTriple,
        ])
      #endif

      #if os(macOS)
        XCTAssert(
            barLinkArgs.contains("-install_name")
                && barLinkArgs.contains("@rpath/libBar-Baz.dylib")
                && barLinkArgs.contains("-rpath")
                && barLinkArgs.contains("@loader_path"),
            "The dynamic library will not work once moved outside the build directory."
        )
      #endif
    }

    func testExecAsDependency() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    products: [
                        ProductDescription(name: "lib", type: .library(.dynamic), targets: ["lib"]),
                    ],
                    targets: [
                        TargetDescription(name: "lib", dependencies: []),
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics, fileSystem: fs)
        )

        result.checkProductsCount(2)
        result.checkTargetsCount(2)

        let exe = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exe, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

        let lib = try result.target(for: "lib").swiftTarget().compileArguments()
        XCTAssertMatch(lib, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

        #if os(macOS)
            let linkArguments = [
                "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
                "-o", "/path/to/build/debug/liblib.dylib", "-module-name", "lib",
                "-emit-library",
                "-Xlinker", "-install_name", "-Xlinker", "@rpath/liblib.dylib",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
                "@/path/to/build/debug/lib.product/Objects.LinkFileList",
                "-target", "x86_64-apple-macosx10.10",
                "-Xlinker", "-add_ast_path", "-Xlinker", "/path/to/build/debug/lib.swiftmodule",
            ]
        #else
            let linkArguments = [
                "/fake/path/to/swiftc", "-L", "/path/to/build/debug",
                "-o", "/path/to/build/debug/liblib.so", "-module-name", "lib",
                "-emit-library", "-Xlinker", "-rpath=$ORIGIN",
                "@/path/to/build/debug/lib.product/Objects.LinkFileList",
                "-target", defaultTargetTriple,
            ]
        #endif

        XCTAssertEqual(try result.buildProduct(for: "lib").linkArguments(), linkArguments)
    }

    func testClangTargets() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.c",
            "/Pkg/Sources/lib/include/lib.h",
            "/Pkg/Sources/lib/lib.cpp"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    products: [
                        ProductDescription(name: "lib", type: .library(.dynamic), targets: ["lib"]),
                    ],
                    targets: [
                        TargetDescription(name: "lib", dependencies: []),
                        TargetDescription(name: "exe", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics,
            fileSystem: fs)
        )

        result.checkProductsCount(2)
        result.checkTargetsCount(2)

        let exe = try result.target(for: "exe").clangTarget()
    #if os(macOS)
        XCTAssertEqual(exe.basicArguments(), ["-fobjc-arc", "-target", defaultTargetTriple, "-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1", "-fblocks",  "-fmodules", "-fmodule-name=exe", "-I", "/Pkg/Sources/exe/include", "-fmodules-cache-path=/path/to/build/debug/ModuleCache"])
    #else
        XCTAssertEqual(exe.basicArguments(), ["-target", defaultTargetTriple, "-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1", "-fblocks",  "-fmodules", "-fmodule-name=exe", "-I", "/Pkg/Sources/exe/include", "-fmodules-cache-path=/path/to/build/debug/ModuleCache"])
    #endif
        XCTAssertEqual(exe.objects, [AbsolutePath("/path/to/build/debug/exe.build/main.c.o")])
        XCTAssertEqual(exe.moduleMap, nil)

        let lib = try result.target(for: "lib").clangTarget()
    #if os(macOS)
        XCTAssertEqual(lib.basicArguments(), ["-fobjc-arc", "-target", defaultTargetTriple, "-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1", "-fblocks",  "-fmodules", "-fmodule-name=lib", "-I", "/Pkg/Sources/lib/include", "-fmodules-cache-path=/path/to/build/debug/ModuleCache"])
    #else
        XCTAssertEqual(lib.basicArguments(), ["-target", defaultTargetTriple, "-g", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1", "-fblocks",  "-fmodules", "-fmodule-name=lib", "-I", "/Pkg/Sources/lib/include", "-fmodules-cache-path=/path/to/build/debug/ModuleCache"])
    #endif
        XCTAssertEqual(lib.objects, [AbsolutePath("/path/to/build/debug/lib.build/lib.cpp.o")])
        XCTAssertEqual(lib.moduleMap, AbsolutePath("/path/to/build/debug/lib.build/module.modulemap"))

    #if os(macOS)
        XCTAssertEqual(try result.buildProduct(for: "lib").linkArguments(), ["/fake/path/to/swiftc", "-lc++", "-L", "/path/to/build/debug", "-o", "/path/to/build/debug/liblib.dylib", "-module-name", "lib", "-emit-library", "-Xlinker", "-install_name", "-Xlinker", "@rpath/liblib.dylib", "-Xlinker", "-rpath", "-Xlinker", "@loader_path", "@/path/to/build/debug/lib.product/Objects.LinkFileList", "-runtime-compatibility-version", "none", "-target", "x86_64-apple-macosx10.10"])
            
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), ["/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable", "-Xlinker", "-rpath", "-Xlinker", "@loader_path", "@/path/to/build/debug/exe.product/Objects.LinkFileList", "-runtime-compatibility-version", "none", "-target", "x86_64-apple-macosx10.10"])
    #else
        XCTAssertEqual(try result.buildProduct(for: "lib").linkArguments(), ["/fake/path/to/swiftc", "-lstdc++", "-L", "/path/to/build/debug", "-o", "/path/to/build/debug/liblib.so", "-module-name", "lib", "-emit-library", "-Xlinker", "-rpath=$ORIGIN", "@/path/to/build/debug/lib.product/Objects.LinkFileList", "-runtime-compatibility-version", "none", "-target", defaultTargetTriple])
        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), ["/fake/path/to/swiftc", "-L", "/path/to/build/debug", "-o", "/path/to/build/debug/exe", "-module-name", "exe", "-emit-executable", "-Xlinker", "-rpath=$ORIGIN", "@/path/to/build/debug/exe.product/Objects.LinkFileList", "-runtime-compatibility-version", "none", "-target", defaultTargetTriple])
    #endif
    }

    func testNonReachableProductsAndTargets() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/main.swift",
            "/B/Sources/BTarget1/BTarget1.swift",
            "/B/Sources/BTarget2/main.swift",
            "/C/Sources/CTarget/main.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "A",
                    path: "/A",
                    url: "/A",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                        PackageDependencyDescription(name: nil, url: "/C", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    products: [
                        ProductDescription(name: "aexec", type: .executable, targets: ["ATarget"])
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BLibrary"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "B",
                    path: "/B",
                    url: "/B",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "BLibrary", type: .library(.static), targets: ["BTarget1"]),
                        ProductDescription(name: "bexec", type: .executable, targets: ["BTarget2"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget1", dependencies: []),
                        TargetDescription(name: "BTarget2", dependencies: []),
                    ]),
                Manifest.createV4Manifest(
                    name: "C",
                    path: "/C",
                    url: "/C",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "cexec", type: .executable, targets: ["CTarget"])
                    ],
                    targets: [
                        TargetDescription(name: "CTarget", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        XCTAssertEqual(Set(graph.reachableProducts.map({ $0.name })), ["aexec", "BLibrary"])
        XCTAssertEqual(Set(graph.reachableTargets.map({ $0.name })), ["ATarget", "BTarget1"])
        XCTAssertEqual(Set(graph.allProducts.map({ $0.name })), ["aexec", "BLibrary", "bexec", "cexec"])
        XCTAssertEqual(Set(graph.allTargets.map({ $0.name })), ["ATarget", "BTarget1", "BTarget2", "CTarget"])

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics,
            fileSystem: fileSystem))

        XCTAssertEqual(Set(result.productMap.keys), ["aexec", "BLibrary", "bexec", "cexec"])
        XCTAssertEqual(Set(result.targetMap.keys), ["ATarget", "BTarget1", "BTarget2", "CTarget"])
    }

    func testSystemPackageBuildPlan() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/module.modulemap"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root
                ),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        XCTAssertThrows(BuildPlan.Error.noBuildableTarget) {
            _ = try BuildPlan(
                buildParameters: mockBuildParameters(),
                graph: graph, diagnostics: diagnostics, fileSystem: fs)
        }
    }

    func testPkgConfigHintDiagnostic() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/A/Sources/BTarget/module.modulemap"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "A",
                    path: "/A",
                    url: "/A",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BTarget"]),
                        TargetDescription(
                            name: "BTarget",
                            type: .system,
                            pkgConfig: "BTarget",
                            providers: [
                                .brew(["BTarget"]),
                                .apt(["BTarget"]),
                            ]
                        )
                    ]),
            ]
        )

        _ = try BuildPlan(buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics, fileSystem: fileSystem)

//        XCTAssertTrue(diagnostics.diagnostics.contains(where: { ($0.message.data is PkgConfigHintDiagnostic) }))
    }

    func testPkgConfigGenericDiagnostic() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/A/Sources/BTarget/module.modulemap"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "A",
                    path: "/A",
                    url: "/A",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BTarget"]),
                        TargetDescription(
                            name: "BTarget",
                            type: .system,
                            pkgConfig: "BTarget"
                        )
                    ]),
            ]
        )

        _ = try BuildPlan(buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics, fileSystem: fileSystem)

        let diagnostic = diagnostics.diagnostics.last!

        XCTAssertEqual(diagnostic.message.text, "couldn't find pc file")
        XCTAssertEqual(diagnostic.message.behavior, .warning)
        XCTAssertEqual(diagnostic.location.description, "'BTarget' BTarget.pc")
    }

    func testWindowsTarget() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
                                    "/Pkg/Sources/lib/lib.c",
                                    "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(
            fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                    TargetDescription(name: "exe", dependencies: ["lib"]),
                    TargetDescription(name: "lib", dependencies: []),
                ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(destinationTriple: .windows), graph: graph, diagnostics: diagnostics, fileSystem: fs))
        result.checkProductsCount(1)
        result.checkTargetsCount(2)

        let lib = try result.target(for: "lib").clangTarget()
        var args = ["-target", "x86_64-unknown-windows-msvc", "-g", "-gcodeview", "-O0", "-DSWIFT_PACKAGE=1", "-DDEBUG=1"]
        args += ["-fblocks", "-I", "/Pkg/Sources/lib/include"]
        XCTAssertEqual(lib.basicArguments(), args)
        XCTAssertEqual(lib.objects, [AbsolutePath("/path/to/build/debug/lib.build/lib.c.o")])
        XCTAssertEqual(lib.moduleMap, AbsolutePath("/path/to/build/debug/lib.build/module.modulemap"))

        let exe = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exe, ["-swift-version", "4", "-enable-batch-mode", "-Onone", "-enable-testing", "-g", .equal(j), "-DSWIFT_PACKAGE", "-DDEBUG","-Xcc", "-fmodule-map-file=/path/to/build/debug/lib.build/module.modulemap", "-I", "/Pkg/Sources/lib/include", "-module-cache-path", "/path/to/build/debug/ModuleCache", .anySequence])

        XCTAssertEqual(try result.buildProduct(for: "exe").linkArguments(), [
            "/fake/path/to/swiftc",
            "-L", "/path/to/build/debug", "-o", "/path/to/build/debug/exe.exe",
            "-module-name", "exe", "-emit-executable",
            "@/path/to/build/debug/exe.product/Objects.LinkFileList",
             "-target", "x86_64-unknown-windows-msvc",
            ])
    }

    func testIndexStore() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.c",
            "/Pkg/Sources/lib/include/lib.h"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        func check(for mode: BuildParameters.IndexStoreMode, config: BuildConfiguration) throws {
            let result = BuildPlanResult(plan: try BuildPlan(buildParameters: mockBuildParameters(config: config, indexStoreMode: mode), graph: graph, diagnostics: diagnostics, fileSystem: fs))

            let lib = try result.target(for: "lib").clangTarget()
            let path = StringPattern.equal(result.plan.buildParameters.indexStore.pathString)

        #if os(macOS)
            XCTAssertMatch(lib.basicArguments(), [.anySequence, "-index-store-path", path, .anySequence])
        #else
            XCTAssertNoMatch(lib.basicArguments(), [.anySequence, "-index-store-path", path, .anySequence])
        #endif

            let exe = try result.target(for: "exe").swiftTarget().compileArguments()
            XCTAssertMatch(exe, [.anySequence, "-index-store-path", path, .anySequence])
        }

        try check(for: .auto, config: .debug)
        try check(for: .on, config: .debug)
        try check(for: .on, config: .release)
    }

    func testPlatforms() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/B/Sources/BTarget/foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createManifest(
                    name: "A",
                    platforms: [
                        PlatformDescription(name: "macos", version: "10.13"),
                    ],
                    path: "/A",
                    url: "/A",
                    v: .v5,
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BLibrary"]),
                    ]),
                Manifest.createManifest(
                    name: "B",
                    platforms: [
                        PlatformDescription(name: "macos", version: "10.12"),
                    ],
                    path: "/B",
                    url: "/B",
                    v: .v5,
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "BLibrary", targets: ["BTarget"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph, diagnostics: diagnostics,
            fileSystem: fileSystem))

        let aTarget = try result.target(for: "ATarget").swiftTarget().compileArguments()
      #if os(macOS)
        XCTAssertMatch(aTarget, ["-target", "x86_64-apple-macosx10.13", .anySequence])
      #else
        XCTAssertMatch(aTarget, [.equal("-target"), .equal(defaultTargetTriple), .anySequence] )
      #endif

        let bTarget = try result.target(for: "BTarget").swiftTarget().compileArguments()
      #if os(macOS)
        XCTAssertMatch(bTarget, ["-target", "x86_64-apple-macosx10.12", .anySequence])
      #else
        XCTAssertMatch(bTarget, [.equal("-target"), .equal(defaultTargetTriple), .anySequence] )
      #endif
    }
    func testPlatformsValidation() throws {
        let fileSystem = InMemoryFileSystem(emptyFiles:
            "/A/Sources/ATarget/foo.swift",
            "/B/Sources/BTarget/foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fileSystem, diagnostics: diagnostics,
            manifests: [
                Manifest.createManifest(
                    name: "A",
                    platforms: [
                        PlatformDescription(name: "macos", version: "10.13"),
                        PlatformDescription(name: "ios", version: "10"),
                    ],
                    path: "/A",
                    url: "/A",
                    v: .v5,
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/B", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "ATarget", dependencies: ["BLibrary"]),
                    ]),
                Manifest.createManifest(
                    name: "B",
                    platforms: [
                        PlatformDescription(name: "macos", version: "10.14"),
                        PlatformDescription(name: "ios", version: "11"),
                    ],
                    path: "/B",
                    url: "/B",
                    v: .v5,
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "BLibrary", targets: ["BTarget"]),
                    ],
                    targets: [
                        TargetDescription(name: "BTarget", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        XCTAssertThrows(Diagnostics.fatalError) {
            _ = try BuildPlan(
                buildParameters: mockBuildParameters(destinationTriple: .macOS),
                graph: graph, diagnostics: diagnostics,
                fileSystem: fileSystem)
        }

        DiagnosticsEngineTester(diagnostics, ignoreNotes: true) { result in
            let diagnosticMessage = """
            the library 'ATarget' requires macos 10.13, but depends on the product 'BLibrary' which requires macos 10.14; \
            consider changing the library 'ATarget' to require macos 10.14 or later, or the product 'BLibrary' to require \
            macos 10.13 or earlier.
            """
            result.check(diagnostic: .contains(diagnosticMessage), behavior: .error)
        }
    }

    func testBuildSettings() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/A/Sources/exe/main.swift",
            "/A/Sources/bar/bar.swift",
            "/A/Sources/cbar/barcpp.cpp",
            "/A/Sources/cbar/bar.c",
            "/A/Sources/cbar/include/bar.h",

            "/B/Sources/t1/dep.swift",
            "/B/Sources/t2/dep.swift",
            "<end>"
        )

        let aManifest = Manifest.createManifest(
            name: "A",
            path: "/A",
            url: "/A",
            v: .v5,
            packageKind: .root,
            dependencies: [
                PackageDependencyDescription(name: nil, url: "/B", requirement: .upToNextMajor(from: "1.0.0")),
            ],
            targets: [
                TargetDescription(
                    name: "cbar",
                    settings: [
                    .init(tool: .c, name: .headerSearchPath, value: ["Sources/headers"]),
                    .init(tool: .cxx, name: .headerSearchPath, value: ["Sources/cppheaders"]),

                    .init(tool: .c, name: .define, value: ["CCC=2"]),
                    .init(tool: .cxx, name: .define, value: ["RCXX"], condition: .init(config: "release")),

                    .init(tool: .c, name: .unsafeFlags, value: ["-Icfoo", "-L", "cbar"]),
                    .init(tool: .cxx, name: .unsafeFlags, value: ["-Icxxfoo", "-L", "cxxbar"]),
                    ]
                ),
                TargetDescription(
                    name: "bar", dependencies: ["cbar", "Dep"],
                    settings: [
                    .init(tool: .swift, name: .define, value: ["LINUX"], condition: .init(platformNames: ["linux"])),
                    .init(tool: .swift, name: .define, value: ["RLINUX"], condition: .init(platformNames: ["linux"], config: "release")),
                    .init(tool: .swift, name: .define, value: ["DMACOS"], condition: .init(platformNames: ["macos"], config: "debug")),
                    .init(tool: .swift, name: .unsafeFlags, value: ["-Isfoo", "-L", "sbar"]),
                    ]
                ),
                TargetDescription(
                    name: "exe", dependencies: ["bar"],
                    settings: [
                    .init(tool: .swift, name: .define, value: ["FOO"]),
                    .init(tool: .linker, name: .linkedLibrary, value: ["sqlite3"]),
                    .init(tool: .linker, name: .linkedFramework, value: ["CoreData"], condition: .init(platformNames: ["macos"])),
                    .init(tool: .linker, name: .unsafeFlags, value: ["-Ilfoo", "-L", "lbar"]),
                    ]
                ),
            ]

        )

        let bManifest = Manifest.createManifest(
            name: "B",
            path: "/B",
            url: "/B",
            v: .v5,
            packageKind: .local,
            products: [
                ProductDescription(name: "Dep", targets: ["t1", "t2"]),
            ],
            targets: [
                TargetDescription(
                    name: "t1",
                    settings: [
                        .init(tool: .swift, name: .define, value: ["DEP"]),
                        .init(tool: .linker, name: .linkedLibrary, value: ["libz"]),
                    ]
                ),
                TargetDescription(
                    name: "t2",
                    settings: [
                        .init(tool: .linker, name: .linkedLibrary, value: ["libz"]),
                    ]
                ),
            ])

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [aManifest, bManifest]
        )
        XCTAssertNoDiagnostics(diagnostics)

        func createResult(for dest: Triple) throws -> BuildPlanResult {
            return BuildPlanResult(plan: try BuildPlan(
                buildParameters: mockBuildParameters(destinationTriple: dest),
                graph: graph, diagnostics: diagnostics,
                fileSystem: fs)
            )
        }

        do {
            let result = try createResult(for: .x86_64Linux)

            let dep = try result.target(for: "t1").swiftTarget().compileArguments()
            XCTAssertMatch(dep, [.anySequence, "-DDEP", .end])

            let cbar = try result.target(for: "cbar").clangTarget().basicArguments()
            XCTAssertMatch(cbar, [.anySequence, "-DCCC=2", "-I/A/Sources/cbar/Sources/headers", "-I/A/Sources/cbar/Sources/cppheaders", "-Icfoo", "-L", "cbar", "-Icxxfoo", "-L", "cxxbar", .end])

            let bar = try result.target(for: "bar").swiftTarget().compileArguments()
            XCTAssertMatch(bar, [.anySequence, "-DLINUX", "-Isfoo", "-L", "sbar", .end])

            let exe = try result.target(for: "exe").swiftTarget().compileArguments()
            XCTAssertMatch(exe, [.anySequence, "-DFOO", .end])

            let linkExe = try result.buildProduct(for: "exe").linkArguments()
            XCTAssertMatch(linkExe, [.anySequence, "-lsqlite3", "-llibz", "-Ilfoo", "-L", "lbar", .end])
        }

        do {
            let result = try createResult(for: .macOS)

            let cbar = try result.target(for: "cbar").clangTarget().basicArguments()
            XCTAssertMatch(cbar, [.anySequence, "-DCCC=2", "-I/A/Sources/cbar/Sources/headers", "-I/A/Sources/cbar/Sources/cppheaders", "-Icfoo", "-L", "cbar", "-Icxxfoo", "-L", "cxxbar", .end])

            let bar = try result.target(for: "bar").swiftTarget().compileArguments()
            XCTAssertMatch(bar, [.anySequence, "-DDMACOS", "-Isfoo", "-L", "sbar", .end])

            let exe = try result.target(for: "exe").swiftTarget().compileArguments()
            XCTAssertMatch(exe, [.anySequence, "-DFOO", "-framework", "CoreData", .end])

            let linkExe = try result.buildProduct(for: "exe").linkArguments()
            XCTAssertMatch(linkExe, [.anySequence, "-lsqlite3", "-llibz", "-framework", "CoreData", "-Ilfoo", "-L", "lbar", .anySequence])
        }
    }

    func testExtraBuildFlags() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/A/Sources/exe/main.swift",
            "/fake/path/lib/libSomething.dylib",
            "<end>"
        )

        let aManifest = Manifest.createManifest(
            name: "A",
            path: "/A",
            url: "/A",
            v: .v5,
            packageKind: .root,
            targets: [
                TargetDescription(name: "exe", dependencies: []),
            ]
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [aManifest]
        )
        XCTAssertNoDiagnostics(diagnostics)

        var flags = BuildFlags()
        flags.linkerFlags = ["-L", "/path/to/foo", "-L/path/to/foo", "-rpath=foo", "-rpath", "foo"]
        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(flags: flags),
            graph: graph, diagnostics: diagnostics,
            fileSystem: fs)
        )

        let exe = try result.buildProduct(for: "exe").linkArguments()
        XCTAssertMatch(exe, [.anySequence, "-L", "/path/to/foo", "-L/path/to/foo", "-Xlinker", "-rpath=foo", "-Xlinker", "-rpath", "-Xlinker", "foo", "-L", "/fake/path/lib"])
    }

    func testExecBuildTimeDependency() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/PkgA/Sources/exe/main.swift",
            "/PkgA/Sources/swiftlib/lib.swift",
            "/PkgB/Sources/PkgB/PkgB.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "PkgA",
                    path: "/PkgA",
                    url: "/PkgA",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "swiftlib", targets: ["swiftlib"]),
                        ProductDescription(name: "exe", type: .executable, targets: ["exe"])
                    ],
                    targets: [
                        TargetDescription(name: "exe", dependencies: []),
                        TargetDescription(name: "swiftlib", dependencies: ["exe"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "PkgB",
                    path: "/PkgB",
                    url: "/PkgB",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/PkgA", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "PkgB", dependencies: ["swiftlib"]),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)

        mktmpdir { path in
            let yaml = path.appending(component: "debug.yaml")
            let llbuild = LLBuildManifestBuilder(plan)
            try llbuild.generateManifest(at: yaml)
            let contents = try localFileSystem.readFileContents(yaml).description
            XCTAssertTrue(contents.contains("""
                    inputs: ["/PkgA/Sources/swiftlib/lib.swift","/path/to/build/debug/exe"]
                    outputs: ["/path/to/build/debug/swiftlib.build/lib.swift.o","/path/to/build/debug/swiftlib.swiftmodule"]
                """), contents)
        }
    }

    func testObjCHeader1() throws {
        // This has a Swift and ObjC target in the same package.
        let fs = InMemoryFileSystem(emptyFiles:
            "/PkgA/Sources/Bar/main.m",
            "/PkgA/Sources/Foo/Foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "PkgA",
                    path: "/PkgA",
                    url: "/PkgA",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "Foo", dependencies: []),
                        TargetDescription(name: "Bar", dependencies: ["Foo"]),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)
        let result = BuildPlanResult(plan: plan)

        let fooTarget = try result.target(for: "Foo").swiftTarget().compileArguments()
        #if os(macOS)
          XCTAssertMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
        #else
          XCTAssertNoMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
        #endif

        let barTarget = try result.target(for: "Bar").clangTarget().basicArguments()
        #if os(macOS)
          XCTAssertMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
        #else
          XCTAssertNoMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
        #endif

        mktmpdir { path in
            let yaml = path.appending(component: "debug.yaml")
            let llbuild = LLBuildManifestBuilder(plan)
            try llbuild.generateManifest(at: yaml)
            let contents = try localFileSystem.readFileContents(yaml).description
            XCTAssertMatch(contents, .contains("""
                  "/path/to/build/debug/Bar.build/main.m.o":
                    tool: clang
                    inputs: ["/path/to/build/debug/Foo.swiftmodule","/PkgA/Sources/Bar/main.m"]
                    outputs: ["/path/to/build/debug/Bar.build/main.m.o"]
                    description: "Compiling Bar main.m"
                """))
        }
    }

    func testObjCHeader2() throws {
        // This has a Swift and ObjC target in different packages with automatic product type.
        let fs = InMemoryFileSystem(emptyFiles:
            "/PkgA/Sources/Bar/main.m",
            "/PkgB/Sources/Foo/Foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "PkgA",
                    path: "/PkgA",
                    url: "/PkgA",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/PkgB", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "Bar", dependencies: ["Foo"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "PkgB",
                    path: "/PkgB",
                    url: "/PkgB",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "Foo", targets: ["Foo"]),
                    ],
                    targets: [
                        TargetDescription(name: "Foo", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)
        let result = BuildPlanResult(plan: plan)

         let fooTarget = try result.target(for: "Foo").swiftTarget().compileArguments()
         #if os(macOS)
           XCTAssertMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
         #else
           XCTAssertNoMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
         #endif

         let barTarget = try result.target(for: "Bar").clangTarget().basicArguments()
         #if os(macOS)
           XCTAssertMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
         #else
           XCTAssertNoMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
         #endif

         mktmpdir { path in
             let yaml = path.appending(component: "debug.yaml")
             let llbuild = LLBuildManifestBuilder(plan)
             try llbuild.generateManifest(at: yaml)
             let contents = try localFileSystem.readFileContents(yaml).description
             XCTAssertMatch(contents, .contains("""
                   "/path/to/build/debug/Bar.build/main.m.o":
                     tool: clang
                     inputs: ["/path/to/build/debug/Foo.swiftmodule","/PkgA/Sources/Bar/main.m"]
                     outputs: ["/path/to/build/debug/Bar.build/main.m.o"]
                     description: "Compiling Bar main.m"
                 """))
         }
    }

    func testObjCHeader3() throws {
        // This has a Swift and ObjC target in different packages with dynamic product type.
        let fs = InMemoryFileSystem(emptyFiles:
            "/PkgA/Sources/Bar/main.m",
            "/PkgB/Sources/Foo/Foo.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "PkgA",
                    path: "/PkgA",
                    url: "/PkgA",
                    packageKind: .root,
                    dependencies: [
                        PackageDependencyDescription(name: nil, url: "/PkgB", requirement: .upToNextMajor(from: "1.0.0")),
                    ],
                    targets: [
                        TargetDescription(name: "Bar", dependencies: ["Foo"]),
                    ]),
                Manifest.createV4Manifest(
                    name: "PkgB",
                    path: "/PkgB",
                    url: "/PkgB",
                    packageKind: .local,
                    products: [
                        ProductDescription(name: "Foo", type: .library(.dynamic), targets: ["Foo"]),
                    ],
                    targets: [
                        TargetDescription(name: "Foo", dependencies: []),
                    ]),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(buildParameters: mockBuildParameters(), graph: graph, diagnostics: diagnostics, fileSystem: fs)
        let dynamicLibraryExtension = plan.buildParameters.triple.dynamicLibraryExtension
        let result = BuildPlanResult(plan: plan)

         let fooTarget = try result.target(for: "Foo").swiftTarget().compileArguments()
         #if os(macOS)
           XCTAssertMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
         #else
           XCTAssertNoMatch(fooTarget, [.anySequence, "-emit-objc-header", "-emit-objc-header-path", "/path/to/build/debug/Foo.build/Foo-Swift.h", .anySequence])
         #endif

         let barTarget = try result.target(for: "Bar").clangTarget().basicArguments()
         #if os(macOS)
           XCTAssertMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
         #else
           XCTAssertNoMatch(barTarget, [.anySequence, "-fmodule-map-file=/path/to/build/debug/Foo.build/module.modulemap", .anySequence])
         #endif

         mktmpdir { path in
             let yaml = path.appending(component: "debug.yaml")
             let llbuild = LLBuildManifestBuilder(plan)
             try llbuild.generateManifest(at: yaml)
             let contents = try localFileSystem.readFileContents(yaml).description
             XCTAssertMatch(contents, .contains("""
                   "/path/to/build/debug/Bar.build/main.m.o":
                     tool: clang
                     inputs: ["/path/to/build/debug/libFoo\(dynamicLibraryExtension)","/PkgA/Sources/Bar/main.m"]
                     outputs: ["/path/to/build/debug/Bar.build/main.m.o"]
                     description: "Compiling Bar main.m"
                 """))
         }
    }

    func testModulewrap() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/lib/lib.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(fs: fs, diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["lib"]),
                        TargetDescription(name: "lib", dependencies: []),
                    ]
                ),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(destinationTriple: .x86_64Linux),
            graph: graph, diagnostics: diagnostics, fileSystem: fs)
        )

        let objects = try result.buildProduct(for: "exe").objects
        XCTAssertTrue(objects.contains(AbsolutePath("/path/to/build/debug/exe.build/exe.swiftmodule.o")), objects.description)
        XCTAssertTrue(objects.contains(AbsolutePath("/path/to/build/debug/lib.build/lib.swiftmodule.o")), objects.description)

        mktmpdir { path in
            let yaml = path.appending(component: "debug.yaml")
            let llbuild = LLBuildManifestBuilder(result.plan)
            try llbuild.generateManifest(at: yaml)
            let contents = try localFileSystem.readFileContents(yaml).description
            XCTAssertMatch(contents, .contains("""
                  "/path/to/build/debug/exe.build/exe.swiftmodule.o":
                    tool: shell
                    inputs: ["/path/to/build/debug/exe.swiftmodule"]
                    outputs: ["/path/to/build/debug/exe.build/exe.swiftmodule.o"]
                    description: "Wrapping AST for exe for debugging"
                    args: ["/fake/path/to/swiftc","-modulewrap","/path/to/build/debug/exe.swiftmodule","-o","/path/to/build/debug/exe.build/exe.swiftmodule.o"]

                  "/path/to/build/debug/lib.build/lib.swiftmodule.o":
                    tool: shell
                    inputs: ["/path/to/build/debug/lib.swiftmodule"]
                    outputs: ["/path/to/build/debug/lib.build/lib.swiftmodule.o"]
                    description: "Wrapping AST for lib for debugging"
                    args: ["/fake/path/to/swiftc","-modulewrap","/path/to/build/debug/lib.swiftmodule","-o","/path/to/build/debug/lib.build/lib.swiftmodule.o"]
                """))
        }
    }

    func testSwiftBundleAccessor() throws {
        // This has a Swift and ObjC target in the same package.
        let fs = InMemoryFileSystem(emptyFiles:
            "/PkgA/Sources/Foo/Foo.swift",
            "/PkgA/Sources/Foo/foo.txt",
            "/PkgA/Sources/Foo/bar.txt",
            "/PkgA/Sources/Bar/Bar.swift"
        )

        let diagnostics = DiagnosticsEngine()

        let graph = loadPackageGraph(
            fs: fs,
            diagnostics: diagnostics,
            manifests: [
                Manifest.createManifest(
                    name: "PkgA",
                    path: "/PkgA",
                    url: "/PkgA",
                    v: .v5_2,
                    packageKind: .root,
                    targets: [
                        TargetDescription(
                            name: "Foo",
                            resources: [
                                .init(rule: .copy, path: "foo.txt"),
                                .init(rule: .process, path: "bar.txt"),
                            ]
                        ),
                        TargetDescription(
                            name: "Bar"
                        ),
                    ]
                )
            ]
        )

        XCTAssertNoDiagnostics(diagnostics)

        let plan = try BuildPlan(
            buildParameters: mockBuildParameters(),
            graph: graph,
            diagnostics: diagnostics,
            fileSystem: fs
        )
        let result = BuildPlanResult(plan: plan)

        let fooTarget = try result.target(for: "Foo").swiftTarget()
        XCTAssertEqual(fooTarget.objects.map{ $0.pathString }, [
            "/path/to/build/debug/Foo.build/Foo.swift.o",
            "/path/to/build/debug/Foo.build/resource_bundle_accessor.swift.o"
        ])

        let resourceAccessor = fooTarget.sources.first{ $0.basename == "resource_bundle_accessor.swift" }!
        let contents = try fs.readFileContents(resourceAccessor).cString
        XCTAssertTrue(contents.contains("extension Foundation.Bundle"), contents)

        let barTarget = try result.target(for: "Bar").swiftTarget()
        XCTAssertEqual(barTarget.objects.map{ $0.pathString }, [
            "/path/to/build/debug/Bar.build/Bar.swift.o",
        ])
    }

    func testBinaryTargets() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Pkg/Sources/exe/main.swift",
            "/Pkg/Sources/Library/Library.swift",
            "/Pkg/Sources/CLibrary/library.c",
            "/Pkg/Sources/CLibrary/include/library.h"
        )

        try! fs.createDirectory(AbsolutePath("/Pkg/Framework.xcframework"), recursive: true)
        try! fs.writeFileContents(
            AbsolutePath("/Pkg/Framework.xcframework/Info.plist"),
            bytes: ByteString(encodingAsUTF8: """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>AvailableLibraries</key>
                    <array>
                        <dict>
                            <key>LibraryIdentifier</key>
                            <string>macos-x86_64</string>
                            <key>LibraryPath</key>
                            <string>Framework.framework</string>
                            <key>SupportedArchitectures</key>
                            <array>
                                <string>x86_64</string>
                            </array>
                            <key>SupportedPlatform</key>
                            <string>macos</string>
                        </dict>
                    </array>
                    <key>CFBundlePackageType</key>
                    <string>XFWK</string>
                    <key>XCFrameworkFormatVersion</key>
                    <string>1.0</string>
                </dict>
                </plist>
                """))

        try! fs.createDirectory(AbsolutePath("/Pkg/StaticLibrary.xcframework"), recursive: true)
        try! fs.writeFileContents(
            AbsolutePath("/Pkg/StaticLibrary.xcframework/Info.plist"),
            bytes: ByteString(encodingAsUTF8: """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>AvailableLibraries</key>
                    <array>
                        <dict>
                            <key>LibraryIdentifier</key>
                            <string>macos-x86_64</string>
                            <key>HeadersPath</key>
                            <string>Headers</string>
                            <key>LibraryPath</key>
                            <string>libStaticLibrary.a</string>
                            <key>SupportedArchitectures</key>
                            <array>
                                <string>x86_64</string>
                            </array>
                            <key>SupportedPlatform</key>
                            <string>macos</string>
                        </dict>
                    </array>
                    <key>CFBundlePackageType</key>
                    <string>XFWK</string>
                    <key>XCFrameworkFormatVersion</key>
                    <string>1.0</string>
                </dict>
                </plist>
                """))

        let diagnostics = DiagnosticsEngine()
        let graph = loadPackageGraph(
            fs: fs,
            diagnostics: diagnostics,
            manifests: [
                Manifest.createV4Manifest(
                    name: "Pkg",
                    path: "/Pkg",
                    url: "/Pkg",
                    packageKind: .root,
                    products: [
                        ProductDescription(name: "exe", type: .executable, targets: ["exe"]),
                        ProductDescription(name: "Library", type: .library(.dynamic), targets: ["Library"]),
                        ProductDescription(name: "CLibrary", type: .library(.dynamic), targets: ["CLibrary"]),
                    ],
                    targets: [
                        TargetDescription(name: "exe", dependencies: ["Library"]),
                        TargetDescription(name: "Library", dependencies: ["Framework"]),
                        TargetDescription(name: "CLibrary", dependencies: ["StaticLibrary"]),
                        TargetDescription(name: "Framework", path: "Framework.xcframework", type: .binary),
                        TargetDescription(name: "StaticLibrary", path: "StaticLibrary.xcframework", type: .binary),
                    ]
                ),
            ]
        )
        XCTAssertNoDiagnostics(diagnostics)

        let result = BuildPlanResult(plan: try BuildPlan(
            buildParameters: mockBuildParameters(destinationTriple: .macOS),
            graph: graph,
            diagnostics: diagnostics,
            fileSystem: fs
        ))
        XCTAssertNoDiagnostics(diagnostics)

        result.checkProductsCount(3)
        result.checkTargetsCount(3)

        let libraryBasicArguments = try result.target(for: "Library").swiftTarget().compileArguments()
        XCTAssertMatch(libraryBasicArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])

        let libraryLinkArguments = try result.buildProduct(for: "Library").linkArguments()
        XCTAssertMatch(libraryLinkArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(libraryLinkArguments, [.anySequence, "-L", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(libraryLinkArguments, [.anySequence, "-framework", "Framework", .anySequence])

        let exeCompileArguments = try result.target(for: "exe").swiftTarget().compileArguments()
        XCTAssertMatch(exeCompileArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])

        let exeLinkArguments = try result.buildProduct(for: "exe").linkArguments()
        XCTAssertMatch(exeLinkArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(exeLinkArguments, [.anySequence, "-L", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(exeLinkArguments, [.anySequence, "-framework", "Framework", .anySequence])

        let clibraryBasicArguments = try result.target(for: "CLibrary").clangTarget().basicArguments()
        XCTAssertMatch(clibraryBasicArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(clibraryBasicArguments, [.anySequence, "-I", "/Pkg/StaticLibrary.xcframework/macos-x86_64/Headers", .anySequence])

        let clibraryLinkArguments = try result.buildProduct(for: "CLibrary").linkArguments()
        XCTAssertMatch(clibraryLinkArguments, [.anySequence, "-F", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(clibraryLinkArguments, [.anySequence, "-L", "/path/to/build/debug", .anySequence])
        XCTAssertMatch(clibraryLinkArguments, ["-lStaticLibrary"])
    }

    func testBinaryTargetFixture() {
      #if os(macOS)
        fixture(name: "BinaryTargets") { prefix in
            do {
                let (stdout, stderr) = try SwiftPMProduct.SwiftRun.execute(["exe"], packagePath: prefix)
                XCTAssertNoMatch(stderr, .contains("warning: "))
                XCTAssertEqual(stdout, """
                    Framework()
                    Library(framework: MyFwk.Framework())

                    """)
            } catch {
                XCTFail("\(error)")
            }

            do {
                let (stdout, stderr) = try SwiftPMProduct.SwiftRun.execute(["cexe"], packagePath: prefix)
                XCTAssertNoMatch(stderr, .contains("warning: "))
                XCTAssertMatch(stdout, .contains("<CLibrary: "))
            } catch {
                XCTFail("\(error)")
            }
        }
      #endif
    }
}

// MARK:- Test Helpers

private enum Error: Swift.Error {
    case error(String)
}

private struct BuildPlanResult {

    let plan: BuildPlan
    let targetMap: [String: TargetBuildDescription]
    let productMap: [String: ProductBuildDescription]

    init(plan: BuildPlan) {
        self.plan = plan
        self.productMap = Dictionary(uniqueKeysWithValues: plan.buildProducts.map{ ($0.product.name, $0) })
        self.targetMap = Dictionary(uniqueKeysWithValues: plan.targetMap.map{ ($0.0.name, $0.1) })
    }

    func checkTargetsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(plan.targetMap.count, count, file: file, line: line)
    }

    func checkProductsCount(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(plan.productMap.count, count, file: file, line: line)
    }

    func target(for name: String) throws -> TargetBuildDescription {
        guard let target = targetMap[name] else {
            throw Error.error("Target \(name) not found.")
        }
        return target
    }

    func buildProduct(for name: String) throws -> ProductBuildDescription {
        guard let product = productMap[name] else {
            // <rdar://problem/30162871> Display the thrown error on macOS
            throw Error.error("Product \(name) not found.")
        }
        return product
    }
}

fileprivate extension TargetBuildDescription {
    func swiftTarget() throws -> SwiftTargetBuildDescription {
        switch self {
        case .swift(let target):
            return target
        default:
            throw Error.error("Unexpected \(self) type found")
        }
    }

    func clangTarget() throws -> ClangTargetBuildDescription {
        switch self {
        case .clang(let target):
            return target
        default:
            throw Error.error("Unexpected \(self) type")
        }
    }
}
