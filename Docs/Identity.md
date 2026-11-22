<!-- copyright:begin
File: Docs/Identity.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Company identity and namespaces

Use this contract when creating or reusing code, packages, applications, resources
and tooling owned by the company. Read the generated allocation below before
choosing names; consult the selected [language profiles](Languages/README.md) for
the actual ecosystem and preserve existing published contracts during adoption.

## This repository's allocation

| Value | Allocation |
| --- | --- |
| Company domain | `aurum-studios.com` |
| Canonical reverse domain | `com.aurum-studios` |
| Allocation kind | `library` |
| Immutable namespace key | `discordkit` |
| Canonical namespace | `com.aurum-studios.libraries.discordkit` |
| Namespace URI | `https://aurum-studios.com/ns/libraries/discordkit` |
| Namespace UUID | `b467fa11-3125-59c2-86af-f22bd630eaf4` |
| Allocation status | `unverified` |

The generated [project configuration](../.air/project.json) records these values
under `identity`. Generation is offline: `unverified` means that the initializer
has not reserved the allocation in a company register or verified any package
registry, domain service, publisher account or externally registered identity.
Do not interpret an existing local copy, deterministic UUID or successful build
as a company-wide lock or proof of worldwide name availability.

## Allocate stable ownership

The exact company roots are `aurum-studios.com` and
`com.aurum-studios`. Preserve the hyphen in canonical reverse-domain
identifiers. Source-language projections below adapt syntax without changing
the allocation's owner or canonical identity.

| Kind | Canonical scope | Ownership |
| --- | --- | --- |
| `project` | `com.aurum-studios.projects.<key>` | One product or application family |
| `library` | `com.aurum-studios.libraries.<key>` | A reusable company library, independent of its first consumer |
| `tool` | `com.aurum-studios.tools.<key>` | A reusable development, build or operations tool |

Choose an explicit, stable namespace key of 1-54 characters using lowercase ASCII
letters, digits and single internal hyphens. The initializer defaults `--namespace-kind` to
`project` and `--namespace-key` to the repository slug. Supply both deliberately
for a shared library or tool. For an existing allocation, supply its recorded
key explicitly: display names, repository locations and Air command slugs may
change without changing ownership or identity.

For example, from the installed skill directory, preview an independently owned
library with its own allocation:

```sh
python3 scripts/new_repo.py /absolute/library-folder \
  --name 'Telemetry' --description 'Shared company telemetry contracts.' \
  --namespace-kind library --namespace-key telemetry \
  --youtrack-pending
```

Its canonical namespace is `com.aurum-studios.libraries.telemetry`.
Applications depend on that package and retain its namespace. Moving the library
to another repository or adding a second consumer does not create another
allocation. Copying and renaming a shared implementation does not establish
reuse or compatible ownership.

Use `.components.<component-key>` beneath an allocation for independently named
components, for example
`com.aurum-studios.projects.orbit-editor.components.core`. Give tests,
examples, plugins, executables, Editor integrations and platform variants distinct
owned component identities wherever the ecosystem needs separate names. Record
component purpose, owner, consumers and compatibility boundaries. Do not invent
a new product allocation merely to name a component of the same product.

## Configuration and deterministic UUIDs

`identity` has the following contract. String projections are candidate names;
their presence does not prove that a real manifest or external service uses them.

| Field | Meaning |
| --- | --- |
| `company.domain` | Exact company DNS domain, `aurum-studios.com` |
| `company.reverse_domain` | Exact canonical reverse domain, `com.aurum-studios` |
| `company.namespace_uuid` | UUIDv5 of the company domain in the standard DNS UUID namespace |
| `kind` | `project`, `library` or `tool`; selects the plural canonical scope |
| `key` | Immutable allocation key, separate from the display name and Air command slug |
| `namespace` | Exact reverse-domain allocation, including its scope and key |
| `uri` | Stable company-domain URI identifying the allocation; generation does not provision its endpoint |
| `uuid` | UUIDv5 of the exact canonical namespace within `company.namespace_uuid` |
| `allocation_status` | Initially `unverified`; company allocation and external claims require separate evidence |
| `identifiers` | Ecosystem projections listed below, to consult before configuring actual components |

The UUID derivation is reproducible with Python's standard library:

```python
import uuid

company_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, "aurum-studios.com")
namespace_uuid = uuid.uuid5(company_uuid, "com.aurum-studios.libraries.discordkit")
```

The same domain and exact canonical namespace intentionally produce the same
UUID. A display-name, slug or folder rename has no effect when the allocation
kind and key stay fixed. A different key or scope represents a different
identity. UUIDv5 supplies stable identity, not a secret, signature, authorization
token or mathematical guarantee against every possible collision. Do not add a
random suffix on every generation or derive identity from a checkout path.

## Syntax-safe ecosystem projections

For source identifiers, preserve key punctuation by replacing each hyphen with
an underscore, then prefix the token with `p_`, `l_` or `t_` for projects,
libraries or tools. These prefixes handle numeric keys and language keywords.
Keep the exact resulting token; deleting hyphens or applying a case conversion
that merges keys would lose information. Thus `foo-bar` and `foobar` remain
distinct. Conventional C# and Swift company/scope words are capitalized, and
their allocation tokens begin `P_`, `L_` or `T_`.

For project key `orbit-editor`, the initializer emits these base projections:

| `identifiers` field | Candidate value |
| --- | --- |
| `java_package` | `com.aurum_studios.projects.p_orbit_editor` |
| `dotnet_namespace` | `Com.AurumStudios.Projects.P_orbit_editor` |
| `swift_module` | `Com_AurumStudios_Projects_P_orbit_editor` |
| `php_namespace` | `Com\AurumStudios\Projects\P_orbit_editor` |
| `c_symbol_prefix` | `com_aurum_studios_projects_p_orbit_editor_` |
| `cpp_namespace` | `com::aurum_studios::projects::p_orbit_editor` |
| `maven_group` | `com.aurum-studios.projects.orbit-editor` |
| `apple_bundle_prefix` | `com.aurum-studios.projects.orbit-editor` |
| `unity_package_prefix` | `com.aurum-studios.projects.orbit-editor` |
| `nuget_package_prefix` | `com.aurum-studios.projects.orbit-editor` |
| `npm_package` | `@aurum-studios/projects.orbit-editor` |
| `composer_package` | `com.aurum-studios/projects.orbit-editor` |
| `paper_namespace` | `com.aurum-studios.projects.orbit-editor` |
| `wordpress_prefix` | `com_aurum_studios_projects_p_orbit_editor_` |
| `wordpress_slug` | `com-aurum-studios-projects-orbit-editor` |
| `environment_prefix` | `COM_AURUM_STUDIOS_PROJECTS_P_ORBIT_EDITOR_` |
| `hostname` | `orbit-editor.projects.aurum-studios.com` |

`wordpress_prefix` provides a source/global-symbol prefix, `wordpress_slug` a
plugin/resource projection, and `environment_prefix` an environment-variable
prefix. These candidates do not configure tooling. Read this repository's exact
values from `identity.identifiers` and record the identifiers each component uses.

Append distinct components using the ecosystem's valid hierarchy. Java, C#,
PHP and C++ use their respective namespace separators; canonical package and
bundle identifiers use `.components.<key>` where valid. Flat Swift modules,
C symbols and WordPress names require explicitly allocated, collision-checked
aliases for the complete component identity. Do not assume flattening dotted
names or joining independently variable strings with underscores is injective.
In C++, avoid leading underscores and double underscores reserved by the language.

Apple bundle IDs, Maven groups, Unity package names and source namespaces are
different contracts. Maven Central explicitly permits the exact hyphenated
reverse domain even when Java source needs `aurum_studios`. Swift imports use
module names, not bundle IDs. C# assembly and NuGet names must be allocated
separately from source namespaces; Unity assembly definitions must distinguish
Runtime, Editor and Tests where present. Objective-C runtime symbols and exported
C symbols need their own collision review even when wrapped by a Swift module.

TypeScript uses package/module exports for reusable APIs; the company package
allocation does not require adding ambient globals or a TypeScript `namespace`.
PHP uses explicit autoload mappings with consistent path/name case. WordPress
also needs owned prefixes for hooks, options, transients, script/style handles
and other global keys: a PHP namespace alone does not protect those resources.
Block names use a hyphenated namespace such as
`com-aurum-studios-projects-orbit-editor/core`; custom REST namespaces include a
version, for example `com-aurum-studios-projects-orbit-editor/v1`.

Keep the canonical namespace as ownership metadata for tooling whose actual
identifier requires another syntax. DNS names must remain beneath
`aurum-studios.com`; reversing the domain produces an identifier, not an owned
hostname. Validate final resource names, environment variables, database keys,
container images, schema IDs and CI artifacts against the selected tool's rules.
Document each actual alias and its canonical owner.

## Reserve, validate and adopt

Before creating a new allocation, consult the company allocation register when
available. Reserve the canonical namespace, URI, UUID, every actual emitted
alias, owner and component relationship. Compare identifiers using their real
case, punctuation and normalization rules, including case-insensitive registries
and filesystems. Record the authoritative allocation receipt and any separate
publisher/domain verification evidence. If the register is unavailable, keep
`allocation_status` unverified and the company-wide reservation pending.

Validate final names before configuring or publishing. The initializer enforces
the Unity package's 50-character Editor-visible limit when Unity is selected;
suffixes and other real component names still need their own checks. npm package
names have a 214-character limit including scope; nuget.org package IDs have a
100-character limit and compare case-insensitively. Other ecosystems impose
their own rules. Use an explicitly shorter allocated key or component alias
when necessary; never truncate silently or remove punctuation to make a name fit.

Do not recycle published identifiers. Existing deployed packages, persistent
data keys, app IDs, namespaces and APIs require an explicit compatibility and
migration decision before renaming. Preserve third-party dependency identities,
standard filenames/keys, required callbacks and protocol-defined names. The
global `$new-repo` command and repository-prefixed Air stage commands retain
their established invocation names; their owning allocation is recorded here.

Generation performs no registry registration, DNS change, publication or product
migration. A local allocation record cannot establish exclusive company-wide
reservation, external publisher rights or runtime compatibility.

## Primary syntax references

- [Java package naming](https://docs.oracle.com/javase/tutorial/java/package/namingpkgs.html)
  explains reverse domains and replacing illegal domain characters.
- [Sonatype namespace registration](https://central.sonatype.org/register/namespace/)
  requires exact reverse-domain spelling for Maven groups and separate verification.
- [Apple bundle identifiers](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)
  defines allowed characters and case-insensitive identity.
- [Swift module identity](https://github.com/swiftlang/swift/blob/main/docs/Modules.md)
  describes module uniqueness, ABI and Objective-C interoperability boundaries.
- [C# identifier rules](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names)
  defines valid source names;
  [NuGet package IDs](https://learn.microsoft.com/nuget/reference/nuspec)
  defines registry identity and length.
- [Unity package naming](https://docs.unity.cn/Manual/cus-naming.html)
  distinguishes reverse-domain packages from source namespaces and gives length limits.
- [C++ identifiers](https://eel.is/c++draft/lex.name)
  defines source syntax and reserved underscore forms.
- [npm package metadata](https://docs.npmjs.com/cli/configuring-npm/package-json/)
  defines package syntax/length;
  [npm scopes](https://docs.npmjs.com/about-scopes/) explains registry ownership.
- [Composer package names](https://getcomposer.org/doc/04-schema.md)
  defines vendor/package syntax;
  [PSR-4](https://www.php-fig.org/psr/psr-4/) defines autoload naming and case.
- [WordPress prefixes](https://developer.wordpress.org/plugins/plugin-basics/best-practices/),
  [block names](https://developer.wordpress.org/block-editor/reference-guides/block-api/block-metadata/)
  and [REST namespaces](https://developer.wordpress.org/rest-api/extending-the-rest-api/adding-custom-endpoints/)
  describe distinct global/resource naming contracts.
- [Paper namespaced keys](https://javadocs.papermc.io/paper/1.21.4/org/bukkit/NamespacedKey.html)
  defines allowed namespace/key characters; check the actual target API before adoption.
