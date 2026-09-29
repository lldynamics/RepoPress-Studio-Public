// PublishingWorkbenchCore remains the compatibility umbrella while domain
// code migrates into explicit leaf modules. New code should import the owning
// module directly; these exports preserve existing source compatibility during
// the staged migration.
@_exported import PublishingAICore
@_exported import PublishingCoreSupport
@_exported import PublishingDomainContracts
@_exported import PublishingGitCore
@_exported import PublishingKnowledgeCore
@_exported import PublishingMarkdownCore
