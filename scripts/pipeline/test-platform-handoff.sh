#!/bin/bash

set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Exercise the retired entrypoint locally. Any attempted Azure/Kubernetes/Helm
# command fails the test; no credentials or network access are needed.
ruby - "$repository_root" <<'RUBY'
require 'yaml'
require 'open3'

repo = ARGV.fetch(0)
load_pipeline = ->(path) { YAML.load_file("#{repo}/pipelines/#{path}") }
installer = load_pipeline.call('stages/install-helm-charts.yaml')
stages = installer.fetch('stages')
abort 'Retired installer must retain one successful handoff stage' unless stages.length == 1
stage = stages.first
abort 'Keep the existing stage identity for downstream sequencing' unless stage.fetch('stage') == 'DeployHelmCharts'
abort 'Handoff stage must not be skipped' if stage.key?('condition')
jobs = stage.fetch('jobs')
abort 'Only a normal ownership-notice job may remain' unless jobs.length == 1 && jobs.first.key?('job')
job = jobs.first
abort 'Handoff must not require an environment or service connection' if job.key?('environment') || job.key?('strategy')
abort 'Ownership notice must complete on every branch' if job.key?('condition')

expand_steps = lambda do |steps, tag_build|
  steps.flat_map do |step|
    if step.keys == ['${{ if parameters.tagBuild }}']
      tag_build ? step.values.first : []
    else
      [step]
    end
  end
end

stubs = <<~'BASH'
  set -euo pipefail
  az() { echo 'UNEXPECTED_CLOUD_MUTATION'; return 99; }
  kubectl() { echo 'UNEXPECTED_CLOUD_MUTATION'; return 99; }
  helm() { echo 'UNEXPECTED_CLOUD_MUTATION'; return 99; }
BASH

%w[DEV TST PRE PRD].product(%w[refs/heads/main refs/heads/feature/platform], [false, true]).each do |environment, branch, tag_build|
  steps = expand_steps.call(job.fetch('steps'), tag_build)
  scripts = steps.map do |step|
    if step.key?('checkout')
      abort 'Handoff must not check out infrastructure code' unless step.fetch('checkout') == 'none'
      next
    end
    abort 'Retired installer may only print ownership and build tags' unless step.key?('bash')
    if step.key?('condition')
      expected = "and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))"
      abort 'Unexpected ownership-notice condition' unless step.fetch('condition') == expected
      next unless branch == 'refs/heads/main'
    end
    step.fetch('bash').gsub('${{ parameters.environmentName }}', environment)
  end.compact
  stdout, stderr, status = Open3.capture3('/bin/bash', stdin_data: stubs + scripts.join("\n"), chdir: repo)
  output = stdout + stderr
  abort "Ownership notice failed: #{output}" unless status.success?
  abort 'Legacy installer attempted a cloud command' if output.include?('UNEXPECTED_CLOUD_MUTATION')
  abort 'Missing environment ownership notice' unless output.include?("charts for #{environment} are owned by DEFRA/ipaffs-manifest")
  tagged = output.include?("##vso[build.addbuildtag]Environment-#{environment}")
  abort 'Environment tagging changed unexpectedly' unless tagged == (tag_build && branch == 'refs/heads/main')
  puts "PASS #{environment} #{branch} tagBuild=#{tag_build}: ownership notice only"
end

standalone = load_pipeline.call('install-helm-charts.yaml')
abort 'Retired standalone installer must not run automatically' unless standalone.fetch('trigger') == 'none' && standalone.fetch('pr') == 'none'
abort 'Retired standalone installer must not load credentials' if standalone.key?('variables')
abort 'Standalone installer must use the handoff' unless standalone.fetch('stages').map { |item| item['template'] } == ['stages/install-helm-charts.yaml']

tail = load_pipeline.call('stages/infra-platform.yaml').fetch('stages')
abort 'Shared application/TST image imports must remain' unless tail.first.fetch('${{ if parameters.importImages }}').first.fetch('template') == 'import-acr-artifacts.yaml'
abort 'Private Link must remain after the successful handoff' unless tail.drop(1).map { |item| item['template'] } == ['install-helm-charts.yaml', 'deploy-bicep-privatelink.yaml']
%w[infrastructure.yaml infra-platform.yaml].each do |entrypoint|
  abort "#{entrypoint} must retain the shared infrastructure tail" unless File.read("#{repo}/pipelines/#{entrypoint}").include?('template: stages/infra-platform.yaml')
end

# Runtime local charts are still consumed through pinned Git revisions. Shared
# application chart producers remain separate from deployment ownership.
%w[agc-gateway ama-metrics-settings app-routing-controller azure-service-operator-config defra-certs external-secrets-azure ms-identity-redirect-handler].each do |chart|
  abort "Missing retained chart source: #{chart}" unless File.file?("#{repo}/helm-charts/#{chart}/Chart.yaml")
end
%w[bootstrap backoffice webapp job].each do |chart|
  abort "Missing shared chart producer: #{chart}" unless File.file?("#{repo}/pipelines/#{chart}-chart.yaml")
end
puts 'PASS all legacy entrypoints converge on the handoff; imports, Private Link, chart sources and producers remain'
RUBY
