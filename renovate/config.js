// Self-hosted Renovate global config, used by pipelines/renovate.yaml.
//
// Credentials come from the pipeline, never from this file:
//   RENOVATE_TOKEN  - Azure Pipelines GitHub App installation token (DEFRA service connection)
//   ADO_FEED_TOKEN  - System.AccessToken (DEFRA-EUTD-IPAFFS Build Service, Contributor on the feed)
//
// The GitHub token can reach every DEFRA repo the app is installed on, so
// repositories are passed explicitly (RENOVATE_REPOSITORIES) and autodiscover
// stays off. Do not enable it.

const preset = require('./default.json');

module.exports = {
  ...preset,

  platform: 'github',
  endpoint: 'https://api.github.com/',
  autodiscover: false,

  // No onboarding PRs: every repo gets the shared preset above. A repo may still
  // add its own renovate.json to override or extend it.
  onboarding: false,
  requireConfig: 'optional',

  // Installation tokens can't call GET /user, so the author must be set.
  // Commits go through the GitHub API so they are signed/verified by GitHub.
  gitAuthor: 'IPAFFS CI Bot <ipaffs-ci-bot@defra.gov.uk>',
  platformCommit: 'enabled',

  hostRules: [
    {
      matchHost: 'pkgs.dev.azure.com',
      username: 'build',
      password: process.env.ADO_FEED_TOKEN,
    },
  ],
};
