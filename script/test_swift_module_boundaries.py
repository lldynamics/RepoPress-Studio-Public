#!/usr/bin/env python3
"""Self-contained regression fixtures for the SwiftPM module-boundary gate."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_swift_module_boundaries.py"


def dependency(name: str) -> dict[str, Any]:
    return {"byName": [name, None]}


def explicit_target_dependency(name: str) -> dict[str, Any]:
    return {"target": [name, None]}


def product(name: str, package: str = "fixture-package") -> dict[str, Any]:
    return {"product": [name, package, None, None]}


def package_product(name: str, kind: str, targets: list[str]) -> dict[str, Any]:
    return {
        "name": name,
        "settings": [],
        "targets": targets,
        "type": {kind: ["automatic"]} if kind == "library" else {kind: None},
    }


def swift_settings(enabled: bool = True) -> list[dict[str, Any]]:
    if not enabled:
        return []
    return [{"kind": {"swiftLanguageMode": {"_0": "6"}}, "tool": "swift"}]


def target(
    name: str,
    target_type: str,
    dependencies: list[dict[str, Any]],
    *,
    swift_six: bool = True,
) -> dict[str, Any]:
    return {
        "name": name,
        "type": target_type,
        "dependencies": dependencies,
        "settings": swift_settings(swift_six),
    }


def valid_payload() -> dict[str, Any]:
    return {
        "name": "FixturePackage",
        "toolsVersion": {"_version": "6.0.0"},
        "products": [
            package_product("PublishingMarkdownCore", "library", ["PublishingMarkdownCore"]),
            package_product("PublishingGitCore", "library", ["PublishingGitCore"]),
            package_product("PublishingAICore", "library", ["PublishingAICore"]),
            package_product(
                "PublishingAgentContracts", "library", ["PublishingAgentContracts"]
            ),
            package_product("PublishingKnowledgeCore", "library", ["PublishingKnowledgeCore"]),
            package_product("PublishingWorkbenchCore", "library", ["PublishingWorkbenchCore"]),
            package_product("PersonalSitePublisherMac", "executable", ["PersonalSitePublisherMac"]),
        ],
        "targets": [
            target("PublishingCoreSupport", "regular", []),
            target("PublishingDomainContracts", "regular", []),
            target(
                "PublishingMarkdownCore",
                "regular",
                [
                    dependency("PublishingCoreSupport"),
                    product("SwiftTreeSitter", "swift-tree-sitter"),
                    product("SwiftTreeSitterLayer", "swift-tree-sitter"),
                    product("TreeSitterMarkdown", "tree-sitter-markdown"),
                ],
            ),
            target(
                "PublishingGitCore",
                "regular",
                [
                    dependency("PublishingCoreSupport"),
                    explicit_target_dependency("PublishingDomainContracts"),
                ],
            ),
            target(
                "PublishingAICore",
                "regular",
                [dependency("PublishingCoreSupport")],
            ),
            target(
                "PublishingAgentContracts",
                "regular",
                [dependency("PublishingAICore")],
            ),
            target(
                "PublishingKnowledgeCore",
                "regular",
                [dependency("PublishingCoreSupport"), dependency("PublishingMarkdownCore")],
            ),
            target(
                "PublishingWorkbenchCore",
                "regular",
                [
                    dependency("PublishingCoreSupport"),
                    dependency("PublishingDomainContracts"),
                    dependency("PublishingMarkdownCore"),
                    dependency("PublishingGitCore"),
                    dependency("PublishingAICore"),
                    dependency("PublishingAgentContracts"),
                    dependency("PublishingKnowledgeCore"),
                ],
            ),
            target("BrowserExtensionProtocolSupport", "regular", []),
            target(
                "PersonalSitePublisherMac",
                "executable",
                [
                    dependency("BrowserExtensionProtocolSupport"),
                    dependency("PublishingAICore"),
                    dependency("PublishingCoreSupport"),
                    dependency("PublishingDomainContracts"),
                    dependency("PublishingGitCore"),
                    dependency("PublishingKnowledgeCore"),
                    dependency("PublishingMarkdownCore"),
                    dependency("PublishingWorkbenchCore"),
                    product("Sparkle", "Sparkle"),
                ],
            ),
            target(
                "PublishingMarkdownCoreTests",
                "test",
                [dependency("PublishingCoreSupport"), dependency("PublishingMarkdownCore")],
            ),
            target(
                "PublishingGitCoreTests",
                "test",
                [dependency("PublishingDomainContracts"), dependency("PublishingGitCore")],
            ),
            target(
                "PublishingDomainContractsTests",
                "test",
                [dependency("PublishingDomainContracts")],
            ),
            target(
                "PublishingAICoreTests",
                "test",
                [dependency("PublishingAICore"), dependency("PublishingCoreSupport")],
            ),
            target(
                "PublishingAgentContractsTests",
                "test",
                [
                    dependency("PublishingAICore"),
                    dependency("PublishingAgentContracts"),
                ],
            ),
            target(
                "PublishingCoreSupportTests",
                "test",
                [dependency("PublishingCoreSupport")],
            ),
            target(
                "PublishingKnowledgeCoreTests",
                "test",
                [dependency("PublishingKnowledgeCore")],
            ),
            target(
                "PublishingWorkbenchCoreTests",
                "test",
                [
                    dependency("BrowserExtensionProtocolSupport"),
                    dependency("PublishingAICore"),
                    dependency("PublishingAgentContracts"),
                    dependency("PublishingCoreSupport"),
                    dependency("PublishingDomainContracts"),
                    dependency("PublishingGitCore"),
                    dependency("PublishingKnowledgeCore"),
                    dependency("PublishingMarkdownCore"),
                    dependency("PublishingWorkbenchCore"),
                ],
            ),
            target(
                "PersonalSitePublisherMacTests",
                "test",
                [
                    dependency("BrowserExtensionProtocolSupport"),
                    dependency("PersonalSitePublisherMac"),
                    dependency("PublishingAICore"),
                    dependency("PublishingCoreSupport"),
                    dependency("PublishingDomainContracts"),
                    dependency("PublishingGitCore"),
                    dependency("PublishingKnowledgeCore"),
                    dependency("PublishingMarkdownCore"),
                    dependency("PublishingWorkbenchCore"),
                ],
            ),
        ],
    }


EXPECTED_EXPORT_SOURCE = """// fixture compatibility umbrella\n@_exported import PublishingAICore\n@_exported import PublishingAgentContracts\n@_exported import PublishingCoreSupport\n@_exported import PublishingDomainContracts\n@_exported import PublishingGitCore\n@_exported import PublishingKnowledgeCore\n@_exported import PublishingMarkdownCore\n"""


def prepare_fixture(root: Path, payload: dict[str, Any]) -> Path:
    sources = root / "Sources"
    for target_name in (
        "PublishingCoreSupport",
        "PublishingDomainContracts",
        "PublishingMarkdownCore",
        "PublishingGitCore",
        "PublishingAICore",
        "PublishingAgentContracts",
        "PublishingKnowledgeCore",
        "PublishingWorkbenchCore",
    ):
        directory = sources / target_name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Fixture.swift").write_text(
            f"public enum {target_name.replace('Publishing', '')}Fixture {{}}\n",
            encoding="utf-8",
        )
    umbrella = sources / "PublishingWorkbenchCore" / "Support" / "PublishingCoreModuleExports.swift"
    umbrella.parent.mkdir(parents=True, exist_ok=True)
    umbrella.write_text(EXPECTED_EXPORT_SOURCE, encoding="utf-8")
    test_source = root / "Tests" / "PublishingWorkbenchCoreTests"
    test_source.mkdir(parents=True, exist_ok=True)
    (test_source / "FixtureTests.swift").write_text(
        "import PublishingWorkbenchCore\n",
        encoding="utf-8",
    )
    leaf_test_source = root / "Tests" / "PublishingMarkdownCoreTests"
    leaf_test_source.mkdir(parents=True, exist_ok=True)
    (leaf_test_source / "FixtureTests.swift").write_text(
        "@testable import PublishingMarkdownCore\n",
        encoding="utf-8",
    )
    contracts_test_source = root / "Tests" / "PublishingAgentContractsTests"
    contracts_test_source.mkdir(parents=True, exist_ok=True)
    (contracts_test_source / "FixtureTests.swift").write_text(
        "@testable import PublishingAgentContracts\n",
        encoding="utf-8",
    )
    (root / "Package.swift").write_text("// fixture manifest\n", encoding="utf-8")
    (root / "Package.resolved").write_text("{}\n", encoding="utf-8")
    dump_path = root / "dump-package.json"
    dump_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    return dump_path


def run_fixture(
    root: Path,
    payload: dict[str, Any],
    *,
    source: str | None = None,
    extra_sources: dict[str, str] | None = None,
    enforce_umbrella_retirement: bool = False,
    workbench_import_maximums: dict[str, int] | None = None,
) -> subprocess.CompletedProcess[str]:
    dump_path = prepare_fixture(root, payload)
    if source is not None:
        umbrella = root / "Sources" / "PublishingWorkbenchCore" / "Support" / "PublishingCoreModuleExports.swift"
        umbrella.write_text(source, encoding="utf-8")
    for relative_path, extra_source in (extra_sources or {}).items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(extra_source, encoding="utf-8")
    command = [
        sys.executable,
        str(GATE),
        "--package-root",
        str(root),
        "--dump-package-json",
        str(dump_path),
        "--report",
        str(root / "report.json"),
    ]
    if enforce_umbrella_retirement:
        command.append("--enforce-umbrella-retirement")
    if workbench_import_maximums is not None:
        baseline = root / "quality-baselines.json"
        baseline.write_text(
            json.dumps(
                {
                    "swiftModuleBoundaryMaximums": {
                        "publishingWorkbenchCoreImportsByScope": workbench_import_maximums
                    }
                },
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        command.extend(["--quality-baseline", str(baseline)])
    return subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
    )


def expect_rejected(
    payload: dict[str, Any],
    *,
    source: str | None = None,
    extra_sources: dict[str, str] | None = None,
    enforce_umbrella_retirement: bool = False,
    workbench_import_maximums: dict[str, int] | None = None,
    message: str | None = None,
) -> None:
    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as temporary:
        result = run_fixture(
            Path(temporary),
            payload,
            source=source,
            extra_sources=extra_sources,
            enforce_umbrella_retirement=enforce_umbrella_retirement,
            workbench_import_maximums=workbench_import_maximums,
        )
        assert result.returncode != 0, result.stdout
        if message is not None:
            assert message in result.stderr, result.stderr


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as temporary:
        root = Path(temporary)
        payload = valid_payload()
        accepted = run_fixture(root, payload)
        assert accepted.returncode == 0, accepted.stderr
        report = root / "report.json"
        first_report = report.read_bytes()
        accepted_again = run_fixture(root, payload)
        assert accepted_again.returncode == 0, accepted_again.stderr
        assert report.read_bytes() == first_report, "report must be deterministic"
        decoded = json.loads(first_report)
        assert decoded["status"] == "passed"
        assert decoded["schemaVersion"] == "2"
        assert decoded["policyVersion"] == "swift-module-boundaries-v3"
        assert decoded["tool"]["version"] == "3"
        assert decoded["targetTypeCounts"] == {"executable": 1, "regular": 9, "test": 9}
        assert [product["name"] for product in decoded["products"]] == [
            "PersonalSitePublisherMac",
            "PublishingAICore",
            "PublishingAgentContracts",
            "PublishingGitCore",
            "PublishingKnowledgeCore",
            "PublishingMarkdownCore",
            "PublishingWorkbenchCore",
        ]
        assert decoded["internalEdges"] == sorted(
            decoded["internalEdges"], key=lambda edge: (edge["from"], edge["to"])
        )
        assert decoded["externalProductEdges"] == sorted(
            decoded["externalProductEdges"], key=lambda edge: (edge["from"], edge["product"])
        )
        assert decoded["topologicalOrder"]
        assert decoded["coreSourceMetrics"]["PublishingAgentContracts"]["swiftFileCount"] == 1
        assert decoded["coreSourceMetrics"]["PublishingWorkbenchCore"]["swiftFileCount"] == 2
        assert decoded["compatibilityUmbrellaConsumerMetrics"]["Tests"]["workbenchImportCount"] == 1
        assert decoded["umbrellaRetirement"]["enforced"] is False
        dependency_audit = decoded["dependencyAudit"]
        assert set(dependency_audit) == {
            "declaredDependenciesWithoutImports",
            "transitiveDependencies",
        }
        assert dependency_audit["declaredDependenciesWithoutImports"] == sorted(
            dependency_audit["declaredDependenciesWithoutImports"],
            key=lambda edge: (edge["from"], edge["to"]),
        )
        assert dependency_audit["transitiveDependencies"] == sorted(
            dependency_audit["transitiveDependencies"],
            key=lambda edge: edge["target"],
        )
        assert all(
            edge["reachableTargets"] == sorted(edge["reachableTargets"])
            for edge in dependency_audit["transitiveDependencies"]
        )
        missing_import_edges = {
            (edge["from"], edge["to"])
            for edge in dependency_audit["declaredDependenciesWithoutImports"]
        }
        assert ("PublishingGitCore", "PublishingCoreSupport") in missing_import_edges
        assert ("PublishingGitCore", "PublishingDomainContracts") in missing_import_edges
        assert ("PublishingWorkbenchCore", "PublishingAICore") not in missing_import_edges
        workbench_reachable = next(
            edge["reachableTargets"]
            for edge in dependency_audit["transitiveDependencies"]
            if edge["target"] == "PublishingWorkbenchCore"
        )
        assert workbench_reachable == sorted(
            [
                "PublishingAICore",
                "PublishingAgentContracts",
                "PublishingCoreSupport",
                "PublishingDomainContracts",
                "PublishingGitCore",
                "PublishingKnowledgeCore",
                "PublishingMarkdownCore",
            ]
        )

        policy_root = Path(temporary) / "does-not-exist"
        policy = subprocess.run(
            [sys.executable, str(GATE), "--describe-policy", "--package-root", str(policy_root)],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "SWIFT_BIN": "/definitely/missing/swift"},
        )
        assert policy.returncode == 0, policy.stderr
        policy_json = json.loads(policy.stdout)
        assert set(policy_json) == {
            "productionDependencies",
            "testDependencies",
            "externalProductModules",
            "externalProductDependencies",
        }
        assert "Sparkle" in policy_json["externalProductModules"]
        assert policy_json["externalProductModules"]["TreeSitterMarkdown"] == [
            "TreeSitterMarkdown",
            "TreeSitterMarkdownInline",
        ]
        assert "PublishingMarkdownCoreTests" in policy_json["testDependencies"]
        assert policy_json["externalProductDependencies"]["PersonalSitePublisherMac"]["Sparkle"] == "Sparkle"
        assert policy_json["externalProductDependencies"]["PublishingMarkdownCore"] == {
            "SwiftTreeSitter": "swift-tree-sitter",
            "SwiftTreeSitterLayer": "swift-tree-sitter",
            "TreeSitterMarkdown": "tree-sitter-markdown",
        }

        bounded = run_fixture(
            root,
            payload,
            workbench_import_maximums={"Sources": 0, "Tests": 1},
        )
        assert bounded.returncode == 0, bounded.stderr
        bounded_report = json.loads(report.read_text(encoding="utf-8"))
        assert bounded_report["umbrellaRetirement"]["maximumsEnforced"] == {
            "Sources": 0,
            "Tests": 1,
        }

    missing_edge = valid_payload()
    git_target = next(item for item in missing_edge["targets"] if item["name"] == "PublishingGitCore")
    git_target["dependencies"] = [dependency("PublishingDomainContracts")]
    expect_rejected(missing_edge, message="PublishingGitCore dependencies differ")

    extra_edge = valid_payload()
    git_target = next(item for item in extra_edge["targets"] if item["name"] == "PublishingGitCore")
    git_target["dependencies"].append(dependency("PublishingAICore"))
    expect_rejected(extra_edge, message="PublishingGitCore dependencies differ")

    missing_ai_support = valid_payload()
    ai_target = next(item for item in missing_ai_support["targets"] if item["name"] == "PublishingAICore")
    ai_target["dependencies"] = []
    expect_rejected(missing_ai_support, message="PublishingAICore dependencies differ")

    extra_ai_edge = valid_payload()
    ai_target = next(item for item in extra_ai_edge["targets"] if item["name"] == "PublishingAICore")
    ai_target["dependencies"].append(dependency("PublishingMarkdownCore"))
    expect_rejected(extra_ai_edge, message="PublishingAICore dependencies differ")

    reverse_agent_contracts = valid_payload()
    contracts_target = next(
        item
        for item in reverse_agent_contracts["targets"]
        if item["name"] == "PublishingAgentContracts"
    )
    contracts_target["dependencies"].append(dependency("PublishingWorkbenchCore"))
    expect_rejected(
        reverse_agent_contracts,
        message="dependency cycle",
    )

    reverse_leaf = valid_payload()
    git_target = next(item for item in reverse_leaf["targets"] if item["name"] == "PublishingGitCore")
    git_target["dependencies"].append(dependency("PublishingWorkbenchCore"))
    expect_rejected(reverse_leaf, message="dependency cycle")

    missing_product = valid_payload()
    missing_product["products"] = [
        product_definition
        for product_definition in missing_product["products"]
        if product_definition["name"] != "PublishingGitCore"
    ]
    expect_rejected(missing_product, message="products violate exact allowlist")

    extra_product = valid_payload()
    extra_product["products"].append(
        package_product("ExtraProduct", "library", ["PublishingGitCore"])
    )
    expect_rejected(extra_product, message="products violate exact allowlist")

    wrong_product_mapping = valid_payload()
    wrong_product_mapping["products"][0]["targets"] = ["PublishingGitCore"]
    expect_rejected(wrong_product_mapping, message="mapping differs from policy")

    missing_test_dependency = valid_payload()
    markdown_tests = next(
        item for item in missing_test_dependency["targets"] if item["name"] == "PublishingMarkdownCoreTests"
    )
    markdown_tests["dependencies"] = [dependency("PublishingMarkdownCore")]
    expect_rejected(missing_test_dependency, message="PublishingMarkdownCoreTests dependencies differ")

    extra_test_dependency = valid_payload()
    markdown_tests = next(
        item for item in extra_test_dependency["targets"] if item["name"] == "PublishingMarkdownCoreTests"
    )
    markdown_tests["dependencies"].append(dependency("PublishingAICore"))
    expect_rejected(extra_test_dependency, message="PublishingMarkdownCoreTests dependencies differ")

    missing_external_product = valid_payload()
    markdown = next(item for item in missing_external_product["targets"] if item["name"] == "PublishingMarkdownCore")
    markdown["dependencies"] = [dependency("PublishingCoreSupport")]
    expect_rejected(missing_external_product, message="external products differ from policy")

    wrong_external_package = valid_payload()
    markdown = next(item for item in wrong_external_package["targets"] if item["name"] == "PublishingMarkdownCore")
    markdown["dependencies"][1] = product("SwiftTreeSitter", "wrong-package")
    expect_rejected(wrong_external_package, message="external products differ from policy")

    transitive_import = valid_payload()
    expect_rejected(
        transitive_import,
        extra_sources={
            "Sources/PublishingGitCore/TransitiveImport.swift": "import PublishingMarkdownCore\n",
        },
        message="imports internal module(s) without direct target dependency",
    )

    import_syntax_fixture = valid_payload()
    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as syntax_temporary:
        syntax_root = Path(syntax_temporary)
        syntax_result = run_fixture(
            syntax_root,
            import_syntax_fixture,
            extra_sources={
                "Sources/PublishingGitCore/ImportSyntax.swift": """/* import PublishingWorkbenchCore */
let ordinary = "import PublishingWorkbenchCore"
let raw = #\"import PublishingWorkbenchCore\"#
let multiline = \"\"\"
import PublishingWorkbenchCore
\"\"\"
let rawMultiline = #\"\"\"
\"#import PublishingWorkbenchCore
\"\"\"#
@preconcurrency public import PublishingCoreSupport
@_spi(Test) internal import PublishingDomainContracts
@_spi(Test)@preconcurrency import PublishingCoreSupport
@_implementationOnly import PublishingCoreSupport
@testable import PublishingDomainContracts
package import struct PublishingCoreSupport.SupportFixture
private import func PublishingDomainContracts.ContractsFixture
fileprivate import PublishingDomainContracts
import PublishingCoreSupport; import PublishingDomainContracts
#if DEBUG
import PublishingCoreSupport
#else
import PublishingDomainContracts
#endif
""",
            },
        )
        assert syntax_result.returncode == 0, syntax_result.stderr

    syntax_rejections = {
        "preconcurrency-inline": ("@preconcurrency import PublishingMarkdownCore\n", 1),
        "spi-inline": ("@_spi(Test) import PublishingMarkdownCore\n", 1),
        "spi-adjacent-import": ("@_spi(Test)import PublishingMarkdownCore\n", 1),
        "spi-adjacent-access": ("@_spi(Test)public import PublishingMarkdownCore\n", 1),
        "spi-adjacent-attribute": ("@_spi(Test)@preconcurrency import PublishingMarkdownCore\n", 1),
        "implementation-only-inline": ("@_implementationOnly import PublishingMarkdownCore\n", 1),
        "preconcurrency": ("@preconcurrency\nimport PublishingMarkdownCore\n", 2),
        "spi": ("@_spi(Test)\nimport PublishingMarkdownCore\n", 2),
        "implementation-only": ("@_implementationOnly\nimport PublishingMarkdownCore\n", 2),
        "public": ("public import PublishingMarkdownCore\n", 1),
        "package": ("package import PublishingMarkdownCore\n", 1),
        "private": ("private import PublishingMarkdownCore\n", 1),
        "fileprivate": ("fileprivate import PublishingMarkdownCore\n", 1),
        "scoped": ("import struct PublishingMarkdownCore.MarkdownCoreFixture\n", 1),
        "cross-line": ("import\nPublishingMarkdownCore\n", 1),
        "semicolon": ("import PublishingCoreSupport; import PublishingMarkdownCore\n", 1),
        "inactive-branch": ("#if false\nimport PublishingMarkdownCore\n#endif\n", 2),
    }
    for name, (rejected_source, line) in syntax_rejections.items():
        syntax_payload = valid_payload()
        expect_rejected(
            syntax_payload,
            extra_sources={f"Sources/PublishingAICore/Import-{name}.swift": rejected_source},
            message=f"Import-{name}.swift:{line}",
        )

    missing_direct_with_location = valid_payload()
    expect_rejected(
        missing_direct_with_location,
        extra_sources={
            "Sources/PublishingGitCore/TransitiveImport.swift": "import PublishingMarkdownCore\n",
        },
        message="TransitiveImport.swift:1",
    )

    third_party_import = valid_payload()
    expect_rejected(
        third_party_import,
        extra_sources={"Sources/PublishingAICore/External.swift": "import Sparkle\n"},
        message="without direct product dependency",
    )

    third_party_inline = valid_payload()
    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as inline_temporary:
        inline_result = run_fixture(
            Path(inline_temporary),
            third_party_inline,
            extra_sources={
                "Sources/PublishingMarkdownCore/Inline.swift": (
                    "import TreeSitterMarkdownInline\n"
                )
            },
        )
        assert inline_result.returncode == 0, inline_result.stderr

    external_reexport = valid_payload()
    expect_rejected(
        external_reexport,
        extra_sources={
            "Sources/PublishingAICore/Reexport.swift": "@_exported import PublishingCoreSupport\n",
        },
        message="re-export outside compatibility umbrella",
    )
    expect_rejected(
        valid_payload(),
        extra_sources={
            "Sources/PublishingAICore/Reexport.swift": "@_spi(Test)@_exported import PublishingCoreSupport\n",
        },
        message="re-export outside compatibility umbrella",
    )

    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as layout_temporary:
        standard_layout = valid_payload()
        git_target = next(item for item in standard_layout["targets"] if item["name"] == "PublishingGitCore")
        git_target.update({"path": "Sources/PublishingGitCore", "sources": [], "exclude": []})
        assert run_fixture(Path(layout_temporary), standard_layout).returncode == 0

    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as null_temporary:
        null_layout = valid_payload()
        git_target = next(item for item in null_layout["targets"] if item["name"] == "PublishingGitCore")
        git_target.update({"path": None, "sources": None, "exclude": None})
        assert run_fixture(Path(null_temporary), null_layout).returncode == 0

    nonstandard_path = valid_payload()
    git_target = next(item for item in nonstandard_path["targets"] if item["name"] == "PublishingGitCore")
    git_target["path"] = "Sources/Elsewhere"
    expect_rejected(nonstandard_path, message="source layout")

    nonempty_sources = valid_payload()
    git_target = next(item for item in nonempty_sources["targets"] if item["name"] == "PublishingGitCore")
    git_target["sources"] = ["Fixture.swift"]
    expect_rejected(nonempty_sources, message="source layout")

    nonempty_exclude = valid_payload()
    git_target = next(item for item in nonempty_exclude["targets"] if item["name"] == "PublishingGitCore")
    git_target["exclude"] = ["Fixture.swift"]
    expect_rejected(nonempty_exclude, message="source layout")

    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-fixture.") as stale_temporary:
        stale_root = Path(stale_temporary)
        assert run_fixture(stale_root, valid_payload()).returncode == 0
        stale_report_payload = valid_payload()
        stale_report_payload["targets"].append(copy.deepcopy(stale_report_payload["targets"][0]))
        stale_result = run_fixture(stale_root, stale_report_payload)
        assert stale_result.returncode != 0
        failed_report = json.loads((stale_root / "report.json").read_text(encoding="utf-8"))
        assert failed_report["status"] == "failed"
        assert failed_report["error"]

        for invalid_baseline in ([], None):
            successful = run_fixture(stale_root, valid_payload())
            assert successful.returncode == 0
            baseline = stale_root / "malformed-baseline.json"
            baseline.write_text(json.dumps(invalid_baseline), encoding="utf-8")
            invalid_result = subprocess.run(
                [*successful.args, "--quality-baseline", str(baseline)],
                text=True, capture_output=True, check=False,
            )
            assert invalid_result.returncode != 0
            failed_report = json.loads((stale_root / "report.json").read_text(encoding="utf-8"))
            assert failed_report["status"] == "failed"
            assert "quality baseline must be an object" in failed_report["error"]

    leaf_test_reverse_edge = valid_payload()
    markdown_tests = next(
        item for item in leaf_test_reverse_edge["targets"] if item["name"] == "PublishingMarkdownCoreTests"
    )
    markdown_tests["dependencies"].append(dependency("PublishingWorkbenchCore"))
    expect_rejected(leaf_test_reverse_edge, message="must not depend on PublishingWorkbenchCore")

    cycle = valid_payload()
    cycle["targets"].extend(
        [
            target("CycleOneTests", "test", [dependency("CycleTwoTests")]),
            target("CycleTwoTests", "test", [dependency("CycleOneTests")]),
        ]
    )
    expect_rejected(cycle, message="dependency cycle")

    missing_swift_six = valid_payload()
    workbench = next(item for item in missing_swift_six["targets"] if item["name"] == "PublishingWorkbenchCore")
    workbench["settings"] = []
    expect_rejected(missing_swift_six, message="not explicitly Swift language mode 6")

    duplicate_swift_six = valid_payload()
    workbench = next(item for item in duplicate_swift_six["targets"] if item["name"] == "PublishingWorkbenchCore")
    workbench["settings"].extend(swift_settings())
    expect_rejected(duplicate_swift_six, message="declares swiftLanguageMode more than once")

    wrong_swift_tool = valid_payload()
    workbench = next(item for item in wrong_swift_tool["targets"] if item["name"] == "PublishingWorkbenchCore")
    workbench["settings"][0]["tool"] = "clang"
    expect_rejected(wrong_swift_tool, message="must use the swift tool")

    duplicate_target = valid_payload()
    duplicate_target["targets"].append(copy.deepcopy(duplicate_target["targets"][0]))
    expect_rejected(duplicate_target, message="duplicate target name")

    malformed_dependency = valid_payload()
    markdown = next(item for item in malformed_dependency["targets"] if item["name"] == "PublishingMarkdownCore")
    markdown["dependencies"].append({"mystery": ["Unknown", None]})
    expect_rejected(malformed_dependency, message="unknown variant")

    malformed_dependency_payload = valid_payload()
    markdown = next(item for item in malformed_dependency_payload["targets"] if item["name"] == "PublishingMarkdownCore")
    markdown["dependencies"].append({"byName": []})
    expect_rejected(malformed_dependency_payload, message="unsupported payload")

    missing_export = EXPECTED_EXPORT_SOURCE.replace("@_exported import PublishingGitCore\n", "")
    expect_rejected(valid_payload(), source=missing_export, message="missing=")
    extra_export = EXPECTED_EXPORT_SOURCE + "@_exported import ExtraModule\n"
    expect_rejected(valid_payload(), source=extra_export, message="extra=")
    duplicate_export = EXPECTED_EXPORT_SOURCE + "@_exported import PublishingAICore\n"
    expect_rejected(valid_payload(), source=duplicate_export, message="duplicate=")

    added_test_target = valid_payload()
    added_test_target["targets"].append(
        target("NewSwiftSixTests", "test", [dependency("PublishingGitCore")])
    )
    expect_rejected(added_test_target, message="test targets violate exact allowlist")

    expect_rejected(
        valid_payload(),
        enforce_umbrella_retirement=True,
        message="umbrella retirement enforcement failed",
    )
    expect_rejected(
        valid_payload(),
        workbench_import_maximums={"Sources": 0, "Tests": 0},
        message="compatibility-import maximum exceeded",
    )

    print("swift module boundaries gate test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
