// This is an empty bicep template that `envs/**/common.bicepparam` can refer to in the `using` statement
//
// Works around a bug in Azure CLI where `using none` somehow gets eval'd and becomes a Python NoneType object :-/
// https://github.com/Azure/bicep/issues/18220
//
// See https://github.com/Azure/azure-cli/pull/32750 for related fix, which was merged today as of writing this
// comment, but needs to make into an Azure CLI release which is used by Azure DevOps