#!/bin/bash

set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Check the deployment ownership boundary without Azure/Kubernetes access.
ruby - "$repository_root" <<'RUBY'
require 'yaml'

repo = ARGV.fetch(0)
load_pipeline = ->(path) { YAML.load_file("#{repo}/pipelines/#{path}") }
retired = %w[
  import-acr-artifacts.yaml
  install-helm-charts.yaml
  stages/import-acr-artifacts.yaml
  stages/install-helm-charts.yaml
  stages/infra-platform.yaml
]
retired.each do |path|
  abort "Retired pipeline still exists: #{path}" if File.exist?("#{repo}/pipelines/#{path}")
end

# Catch callers in every pipeline, including references nested under ADO
# compile-time expressions. Service chart deployment templates remain supported.
walk = lambda do |value, path|
  case value
  when Hash
    value.each do |key, nested|
      if key == 'template' && retired.any? { |name| nested.sub(%r{\A/}, '') == name || nested == "stages/#{name}" }
        abort "#{path} still calls retired template #{nested}"
      end
      walk.call(nested, path)
    end
  when Array
    value.each { |nested| walk.call(nested, path) }
  end
end
Dir.glob("#{repo}/pipelines/**/*.{yaml,yml}").each do |path|
  walk.call(YAML.load_file(path), path)
end

infrastructure = load_pipeline.call('infrastructure.yaml')
platform_parameter = infrastructure.fetch('parameters').find { |parameter| parameter['name'] == 'includePlatform' }
abort 'Preserve the optional infrastructure Private Link tail' unless platform_parameter && platform_parameter.fetch('default') == true
private_link_tail = infrastructure.fetch('stages').last
expected_tail = {
  '${{ if parameters.includePlatform }}' => [{
    'template' => 'stages/deploy-bicep-privatelink.yaml',
    'parameters' => { 'environmentName' => '${{ parameters.environmentName }}' }
  }]
}
abort 'Infrastructure must end with optional Private Link only' unless private_link_tail == expected_tail

standalone = load_pipeline.call('infra-platform.yaml')
abort 'Standalone Private Link must retain its manual trigger' unless standalone.fetch('trigger') == 'none'
standalone_stages = standalone.fetch('stages')
expected_tag = {
  "${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}" => [{
    'stage' => 'TagBuild',
    'displayName' => 'Tag environment',
    'jobs' => [{
      'job' => 'TagEnvironment',
      'steps' => [{ 'checkout' => 'none' }, {
        'bash' => 'echo "##vso[build.addbuildtag]Environment-${{ parameters.environmentName }}"',
        'displayName' => 'Tag environment'
      }]
    }]
  }]
}
abort 'Standalone environment tagging must remain main-only' unless standalone_stages.first == expected_tag
abort 'Standalone pipeline must invoke Private Link directly' unless standalone_stages.drop(1) == expected_tail.values.first
abort 'Deleted stage paths must not remain in the PR filter' if standalone.fetch('pr').fetch('paths').fetch('include').any? { |path| retired.any? { |name| path == "pipelines/#{name}" } }

private_link = load_pipeline.call('stages/deploy-bicep-privatelink.yaml').fetch('stages')
abort 'Private Link stage identity must remain stable' unless private_link.length == 1 && private_link.first.fetch('stage') == 'PrivateLink'
deployment = private_link.first.fetch('jobs').find { |job| job['deployment'] == 'RunBicep' }
abort 'Private Link must preserve environment approvals' unless deployment.fetch('environment') == { 'name' => '${{ parameters.environmentName }}' }
steps = deployment.fetch('strategy').fetch('runOnce').fetch('deploy').fetch('steps')
what_if = steps.find { |step| step['displayName'] == 'WhatIf - PrivateLink' }
abort 'Private Link what-if must run on branch previews' unless what_if && !what_if.key?('condition')
main_only = "and(not(failed()), not(canceled()), eq(variables['Build.SourceBranch'], 'refs/heads/main'))"
['Deploy - PrivateLink', 'Wait for Deployment - PrivateLink'].each do |name|
  step = steps.find { |item| item['displayName'] == name }
  abort "#{name} must remain main-only" unless step && step.fetch('condition') == main_only
end
%w[infrastructure.yaml infra-platform.yaml stages/deploy-bicep-privatelink.yaml].each do |path|
  source = File.read("#{repo}/pipelines/#{path}")
  abort "Platform image import remains in #{path}" if source.match?(/az\s+acr\s+import/)
  abort "Platform Helm installation remains in #{path}" if source.match?(/\bhelm\s+(?:install|upgrade|uninstall)\b|HelmDeploy@/)
end
puts 'PASS retired entrypoints and callers removed; Private Link previews, apply guard and tagging preserved'

# Pinned manifest chart sources and shared service-chart producers remain usable.
%w[agc-gateway ama-metrics-settings app-routing-controller azure-service-operator-config defra-certs external-secrets-azure ms-identity-redirect-handler].each do |chart|
  abort "Missing retained chart source: #{chart}" unless File.file?("#{repo}/helm-charts/#{chart}/Chart.yaml")
end
%w[bootstrap backoffice webapp job].each do |chart|
  abort "Missing shared chart producer: #{chart}" unless File.file?("#{repo}/pipelines/#{chart}-chart.yaml")
end
abort 'Shared service chart deployment must remain available' unless File.file?("#{repo}/pipelines/steps/deploy-chart.yaml")
puts 'PASS manifest chart sources and shared service chart producers retained'
RUBY
